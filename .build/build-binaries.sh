#!/bin/bash
#
# build-binaries.sh builds the component binaries from the pinned upstream
# sources and stages them under ./binaries/ so they can be shipped in the
# mlab-node Debian package. The version pins are the same tags the historical
# docker-compose deployment ran (via the corresponding container images), but
# everything is built from source here: no container images, no Docker, no
# skopeo — just git, go and a C toolchain (for scamper and the cgo builds).
#
# Building from source (rather than extracting binaries from the images, as an
# earlier iteration of this script did) is what makes non-amd64 packages
# possible at all: M-Lab publishes amd64-only images, but the sources build
# anywhere Go and gcc do.
#
# Each Go component replicates its upstream Dockerfile's build: same package
# path, same CGO setting, same -ldflags (version stamps). The one divergence is
# ndt-server: upstream builds it CGO+musl-static on Alpine; here it is built
# CGO+glibc-dynamic, which runs natively on Debian (dh_shlibdeps picks up the
# libc dependency).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/binaries"

# The staged tree is fresh only if it was produced by this exact script
# (the version pins live in it): the stamp records the script's hash and is
# written only after a fully successful run. Editing the script (e.g. bumping
# a pinned tag) or an interrupted build invalidates it.
STAMP_FILE="${OUT_DIR}/.build-stamp"
SCRIPT_HASH="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
if [ "$(cat "${STAMP_FILE}" 2>/dev/null)" = "${SCRIPT_HASH}" ]; then
  echo "binaries/ already staged by this script version; skipping build"
  exit 0
fi

# Version pins. These mirror the image tags pinned in the original
# docker-compose.yml (each image was built from the repo tag of the same name).
# NOTE: the annotation2 schema generator intentionally comes from an older
# uuid-annotator tag (v0.5.8) than the running annotator (v0.5.10), matching
# the compose configuration.
# NOTE: heartbeat lives in the m-lab/locate repository (cmd/heartbeat); the
# measurementlab/heartbeat image was built from locate's tags.
NDT_SERVER_VERSION="v0.25.2"
LOCATE_VERSION="v0.19.1"
UUID_ANNOTATOR_VERSION="v0.5.10"
UUID_ANNOTATOR_SCHEMA_VERSION="v0.5.8"
JOSTLER_VERSION="v1.1.4"
TRACEROUTE_VERSION="v0.12.0"
AUTOJOIN_VERSION="v0.2.13"
NODE_EXPORTER_VERSION="v1.9.0"

# scamper is a C tool; the traceroute-caller repo vendors the exact tarball its
# image builds (third_party/scamper), so we build that same tarball.
SCAMPER_DIST="scamper-cvs-20230302"

# ndt-server's go.mod carries a bare "go 1.25" directive, which a system go
# older than 1.25 mis-resolves to a non-existent "go1.25" toolchain download.
# Pin a real release; go fetches it on demand if the system go is older.
NDT_GO_TOOLCHAIN="go1.25.11"

for tool in go git gcc make file; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: required build tool '${tool}' not found in PATH" >&2
    exit 1
  }
done

# The work tree (sources + Go module/build caches) runs to a couple of GB, so
# keep it inside the repo rather than under /tmp, which is often a small tmpfs.
# The Go module cache is written read-only; restore write permission before
# removing so cleanup never fails the script.
WORK_DIR="$(mktemp -d "${REPO_DIR}/.build-work.XXXXXX")"
trap 'chmod -R u+rwX "${WORK_DIR}" 2>/dev/null || true; rm -rf "${WORK_DIR}" 2>/dev/null || true' EXIT

# Hermetic Go state: modules, build cache and on-demand toolchains all live
# under WORK_DIR, so a build never depends on (or pollutes) the host's Go dirs.
export GOPATH="${WORK_DIR}/go"
export GOCACHE="${WORK_DIR}/gocache"
export GOFLAGS="-trimpath -mod=readonly"

# check_binary PATH — sanity-check the produced ELF. Everything is built
# against glibc (static or dynamic) by construction; this catches accidental
# linkage against anything that would not resolve on the target (e.g. a
# scamper private .so if --disable-shared regressed) and logs what was built.
check_binary() {
  local bin="$1" info
  info="$(file -L "${bin}")"
  case "${info}" in
    *"statically linked"* | *"static-pie linked"*) ;;
    *"dynamically linked"*)
      if echo "${info}" | grep -q "ld-musl"; then
        echo "ERROR: ${bin##*/} is musl-linked and would not run on the target." >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: ${bin} does not look like an executable: ${info}" >&2
      exit 1
      ;;
  esac
  echo "   ${bin##*/}: ${info#*: }"
}

# clone_repo NAME URL TAG — shallow-clone URL at TAG (once per NAME+TAG) and
# print the checkout directory. The clone keeps enough git metadata for the
# upstream version -ldflags (git describe / git log on the tagged commit).
clone_repo() {
  local name="$1" url="$2" tag="$3"
  local src="${WORK_DIR}/src/${name}-${tag}"
  if [ ! -d "${src}" ]; then
    git clone --quiet --depth 1 --branch "${tag}" "${url}" "${src}" >&2
  fi
  echo "${src}"
}

# short_commit SRC_DIR — the abbreviated hash of the tagged commit, used by the
# m-lab repos to stamp prometheusx.GitShortCommit (exposed as a metric label).
short_commit() { git -C "$1" log -1 --format=%h; }

# go_build SRC_DIR PKG_DIR DEST CGO [LDFLAGS [GOTOOLCHAIN]]
# Build the Go main package at SRC_DIR/PKG_DIR into OUT_DIR/DEST. Runs from
# within PKG_DIR so nested modules (cmd/generate-schemas in ndt-server) build
# against their own go.mod.
go_build() {
  local src="$1" pkg="$2" dest="$3" cgo="$4" ldflags="${5:-}" toolchain="${6:-}"
  # cgo builds link dynamically anyway, so build them PIE for ASLR (lintian:
  # hardening-no-pie); pure-Go builds stay internally-linked static, where
  # -buildmode=pie does not apply.
  local pie=""
  [ "${cgo}" = "1" ] && pie="-buildmode=pie"
  echo ">> building ${dest} (${src##*/} ${pkg})"
  (
    cd "${src}/${pkg}"
    CGO_ENABLED="${cgo}" \
    GOTOOLCHAIN="${toolchain:-auto}" \
      go build ${pie} ${ldflags:+-ldflags "${ldflags}"} -o "${OUT_DIR}/${dest}" .
  )
  check_binary "${OUT_DIR}/${dest}"
}

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# --- ndt-server (+ ndt7 schema generator) -----------------------------------
# Upstream build.sh: CGO on (the ndt5 BBR code is cgo), stamped with the tag
# and short commit. cmd/generate-schemas is a nested Go module, so it is built
# from within its own directory.
src="$(clone_repo ndt-server https://github.com/m-lab/ndt-server.git "${NDT_SERVER_VERSION}")"
go_build "${src}" . ndt-server 1 \
  "-X github.com/m-lab/ndt-server/version.Version=${NDT_SERVER_VERSION} \
   -X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${src}")" \
  "${NDT_GO_TOOLCHAIN}"
go_build "${src}" cmd/generate-schemas generate-schemas-ndt7 1 "" "${NDT_GO_TOOLCHAIN}"

# --- heartbeat (from m-lab/locate) -------------------------------------------
src="$(clone_repo locate https://github.com/m-lab/locate.git "${LOCATE_VERSION}")"
go_build "${src}" cmd/heartbeat heartbeat 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${src}")"

# --- uuid-annotator (+ annotation2 schema generator, older pin) ---------------
src="$(clone_repo uuid-annotator https://github.com/m-lab/uuid-annotator.git "${UUID_ANNOTATOR_VERSION}")"
go_build "${src}" . uuid-annotator 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${src}")"

# The IPInfo AS-names CSV the annotator reads via -asname.url. The image
# shipped it at /data and pointed at it with a container ENV; systemd units
# have no image ENVs, so the package ships the file and passes the flag.
install -D -m 0644 "${src}/data/asnames.ipinfo.csv" "${OUT_DIR}/asnames.ipinfo.csv"
echo "   asnames.ipinfo.csv: $(wc -c <"${OUT_DIR}/asnames.ipinfo.csv" | tr -d ' ') bytes"

src="$(clone_repo uuid-annotator https://github.com/m-lab/uuid-annotator.git "${UUID_ANNOTATOR_SCHEMA_VERSION}")"
go_build "${src}" cmd/generate-schemas generate-schemas-annotation2 0

# --- jostler -------------------------------------------------------------------
# Upstream also stamps main.Version (git describe, i.e. the tag) and
# main.GitCommit (the full hash).
src="$(clone_repo jostler https://github.com/m-lab/jostler.git "${JOSTLER_VERSION}")"
go_build "${src}" cmd/jostler jostler 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${src}") \
   -X main.Version=${JOSTLER_VERSION} \
   -X main.GitCommit=$(git -C "${src}" log -1 --format=%H)"

# --- traceroute-caller (+ traceroute schema generator + scamper) ---------------
src="$(clone_repo traceroute-caller https://github.com/m-lab/traceroute-caller.git "${TRACEROUTE_VERSION}")"
go_build "${src}" . traceroute-caller 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${src}")"
go_build "${src}" cmd/generate-schemas generate-schemas-traceroute 0

# scamper: build the exact tarball the traceroute-caller image vendors.
# --disable-shared statically links scamper's internal libraries into the
# binary, so the package can ship the single file with no private .so deps.
# OpenSSL is deliberately not linked: configure would silently pick it up if
# the dev headers happen to be installed, making the build host-dependent. The
# image's scamper was built without it, and traceroute-caller does not use the
# TLS probes. There is no --without-openssl switch (AX_CHECK_OPENSSL), so point
# the search at an empty directory instead.
echo ">> building scamper (${SCAMPER_DIST}, vendored in traceroute-caller)"
scamper_build="${WORK_DIR}/scamper"
scamper_prefix="${WORK_DIR}/scamper-install"
mkdir -p "${scamper_build}"
tar -xzf "${src}/third_party/scamper/${SCAMPER_DIST}.tar.gz" -C "${scamper_build}"
(
  cd "${scamper_build}/${SCAMPER_DIST}"
  chmod +x ./configure
  ./configure --quiet --prefix="${scamper_prefix}" --disable-shared --with-openssl=/nonexistent
  make --quiet -j"$(nproc)" >/dev/null
  make --quiet install >/dev/null
)
install -m 0755 "${scamper_prefix}/bin/scamper" "${OUT_DIR}/scamper"
check_binary "${OUT_DIR}/scamper"

# --- autojoin-register ----------------------------------------------------------
src="$(clone_repo autojoin https://github.com/m-lab/autojoin.git "${AUTOJOIN_VERSION}")"
go_build "${src}" cmd/register autojoin-register 0 \
  "-s -w -X main.Version=${AUTOJOIN_VERSION}"

# --- node-exporter ---------------------------------------------------------------
src="$(clone_repo node_exporter https://github.com/prometheus/node_exporter.git "${NODE_EXPORTER_VERSION}")"
go_build "${src}" . node-exporter 0 \
  "-X github.com/prometheus/common/version.Version=${NODE_EXPORTER_VERSION#v} \
   -X github.com/prometheus/common/version.Revision=$(git -C "${src}" log -1 --format=%H) \
   -X github.com/prometheus/common/version.Branch=HEAD"

printf '%s\n' "${SCRIPT_HASH}" > "${STAMP_FILE}"
echo
echo "Staged $(ls -1 "${OUT_DIR}" | wc -l | tr -d ' ') artifacts in ${OUT_DIR}"
