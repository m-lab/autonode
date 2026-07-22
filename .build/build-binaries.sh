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
# path, same CGO setting, same -ldflags (version stamps). Divergences from
# upstream:
#   - ndt-server is built CGO+glibc-dynamic instead of CGO+musl-static on
#     Alpine; it runs natively on Debian (dh_shlibdeps picks up the libc dep).
#   - all binaries are linked with -s -w (no symbol table, no DWARF), roughly
#     halving them. Panic backtraces stay fully symbolized (Go's pclntab is
#     unaffected); only delve/pprof against the shipped binary lose fidelity.
#
# Caching: every component carries its own stamp under binaries/.stamps/,
# keyed on its recipe (pinned tag, package path, build flags, toolchain
# versions). Re-running the script rebuilds only components whose recipe
# changed — bumping one version pin rebuilds that one component. Delete
# binaries/ (or bump STAMP_SCHEMA below) to force a full rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/binaries"
STAMP_DIR="${OUT_DIR}/.stamps"

# Salt mixed into every recipe key. Bump it to invalidate all cached
# components at once, e.g. when the build logic itself changes in a way the
# per-component keys cannot see.
STAMP_SCHEMA=1

# Version pins. These mirror the image tags pinned in the original
# docker-compose.yml (each image was built from the repo tag of the same name).
# NOTE: the annotation2 schema generator intentionally comes from an older
# uuid-annotator tag (v0.5.8) than the running annotator (v0.5.10), matching
# the compose configuration.
# NOTE: heartbeat lives in the m-lab/locate repository (cmd/heartbeat); the
# measurementlab/heartbeat image was built from locate's tags.
NDT_SERVER_VERSION="v0.25.3"
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

# Toolchain fingerprints for the recipe keys: a Go upgrade invalidates every
# component; a gcc/glibc change only the native (cgo/C) ones, whose output —
# including the computed libc6 dependency — depends on the host toolchain.
GO_VERSION="$(go version | awk '{print $3}')"
NATIVE_TOOLCHAIN="gcc=$(gcc -dumpfullversion) libc=$(getconf GNU_LIBC_VERSION)"

# The work tree (sources + Go module/build caches) runs to a couple of GB, so
# keep it inside the repo rather than under /tmp, which is often a small tmpfs.
# The Go module cache is written read-only; restore write permission before
# removing so cleanup never fails the script.
WORK_DIR="$(mktemp -d "${REPO_DIR}/.build-work.XXXXXX")"
trap 'chmod -R u+rwX "${WORK_DIR}" 2>/dev/null || true; rm -rf "${WORK_DIR}" 2>/dev/null || true' EXIT

# Hermetic Go state by default: modules, build cache and on-demand toolchains
# all live under WORK_DIR, so a build never depends on (or pollutes) the
# host's Go dirs. CI overrides AUTONODE_GOPATH/AUTONODE_GOCACHE to persistent
# directories so modules and compiled packages survive across runs (only
# WORK_DIR is removed by the EXIT trap).
export GOPATH="${AUTONODE_GOPATH:-${WORK_DIR}/go}"
export GOCACHE="${AUTONODE_GOCACHE:-${WORK_DIR}/gocache}"
# -modcacherw keeps the module cache writable so cleanup and CI cache
# handling never trip over go's default read-only files (belt and braces
# with the chmod in the EXIT trap).
export GOFLAGS="-trimpath -mod=readonly -modcacherw"

BUILT=0
SKIPPED=0

# recipe_key ARGS... — cache key for one component: a hash of everything that
# determines its output except the sources themselves, which are pinned by
# tag and therefore immutable.
recipe_key() {
  printf '%s\n' "schema=${STAMP_SCHEMA}" "go=${GO_VERSION}" \
    "goflags=${GOFLAGS}" "$@" | sha256sum | awk '{print $1}'
}

# needs_build NAME KEY OUTPUTS... — decide whether NAME must be (re)built.
# Only a matching stamp with every staged output present counts as cached.
needs_build() {
  local name="$1" key="$2" out ok=1
  shift 2
  [ "$(cat "${STAMP_DIR}/${name}" 2>/dev/null)" = "${key}" ] || ok=0
  for out in "$@"; do
    [ -e "${OUT_DIR}/${out}" ] || ok=0
  done
  if [ "${ok}" = 1 ]; then
    echo "   ${name}: cached, skipping"
    SKIPPED=$((SKIPPED + 1))
    return 1
  fi
  rm -f "${STAMP_DIR}/${name}"
  return 0
}

# stamp NAME KEY — record a successful component build.
stamp() {
  mkdir -p "${STAMP_DIR}"
  printf '%s\n' "$2" > "${STAMP_DIR}/$1"
  BUILT=$((BUILT + 1))
}

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
  # Ship stripped: -s (symbol table) -w (DWARF); see the header comment.
  ldflags="-s -w${ldflags:+ ${ldflags}}"
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
      go build ${pie} -ldflags "${ldflags}" -o "${OUT_DIR}/${dest}" .
  )
  check_binary "${OUT_DIR}/${dest}"
}

# build_go DEST URL TAG PKG_DIR CGO [LDFLAGS_TEMPLATE [GOTOOLCHAIN]]
# Cached build of one Go component: skipped entirely (including the clone)
# when its recipe key matches the stamp of a previous run. LDFLAGS_TEMPLATE
# may reference @COMMIT@ / @COMMIT_FULL@, replaced with the short/full hash of
# the tagged commit — a pure function of TAG, hence not part of the key.
build_go() {
  local dest="$1" url="$2" tag="$3" pkg="$4" cgo="$5" tmpl="${6:-}" toolchain="${7:-}"
  local native=""
  [ "${cgo}" = "1" ] && native="${NATIVE_TOOLCHAIN}"
  local key
  key="$(recipe_key "url=${url}" "tag=${tag}" "pkg=${pkg}" "cgo=${cgo}" \
    "ldflags=${tmpl}" "toolchain=${toolchain}" "native=${native}")"
  needs_build "${dest}" "${key}" "${dest}" || return 0
  local src
  src="$(clone_repo "$(basename "${url}" .git)" "${url}" "${tag}")"
  local ldflags="${tmpl//@COMMIT@/$(short_commit "${src}")}"
  ldflags="${ldflags//@COMMIT_FULL@/$(git -C "${src}" log -1 --format=%H)}"
  go_build "${src}" "${pkg}" "${dest}" "${cgo}" "${ldflags}" "${toolchain}"
  stamp "${dest}" "${key}"
}

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/.build-stamp" # pre-.stamps/ whole-script stamp, now unused

# --- ndt-server (+ ndt7 schema generator) -----------------------------------
# Upstream build.sh: CGO on (the ndt5 BBR code is cgo), stamped with the tag
# and short commit. cmd/generate-schemas is a nested Go module, so it is built
# from within its own directory.
NDT_SERVER_URL="https://github.com/m-lab/ndt-server.git"
build_go ndt-server "${NDT_SERVER_URL}" "${NDT_SERVER_VERSION}" . 1 \
  "-X github.com/m-lab/ndt-server/version.Version=${NDT_SERVER_VERSION} \
   -X github.com/m-lab/go/prometheusx.GitShortCommit=@COMMIT@" \
  "${NDT_GO_TOOLCHAIN}"
build_go generate-schemas-ndt7 "${NDT_SERVER_URL}" "${NDT_SERVER_VERSION}" \
  cmd/generate-schemas 1 "" "${NDT_GO_TOOLCHAIN}"

# --- heartbeat (from m-lab/locate) -------------------------------------------
build_go heartbeat https://github.com/m-lab/locate.git "${LOCATE_VERSION}" \
  cmd/heartbeat 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=@COMMIT@"

# --- uuid-annotator (+ annotation2 schema generator, older pin) ---------------
UUID_ANNOTATOR_URL="https://github.com/m-lab/uuid-annotator.git"
build_go uuid-annotator "${UUID_ANNOTATOR_URL}" "${UUID_ANNOTATOR_VERSION}" . 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=@COMMIT@"

# The IPInfo AS-names CSV the annotator reads via -asname.url. The image
# shipped it at /data and pointed at it with a container ENV; systemd units
# have no image ENVs, so the package ships the file and passes the flag.
key="$(recipe_key "component=asnames" "url=${UUID_ANNOTATOR_URL}" \
  "tag=${UUID_ANNOTATOR_VERSION}")"
if needs_build asnames.ipinfo.csv "${key}" asnames.ipinfo.csv; then
  src="$(clone_repo uuid-annotator "${UUID_ANNOTATOR_URL}" "${UUID_ANNOTATOR_VERSION}")"
  install -D -m 0644 "${src}/data/asnames.ipinfo.csv" "${OUT_DIR}/asnames.ipinfo.csv"
  echo "   asnames.ipinfo.csv: $(wc -c <"${OUT_DIR}/asnames.ipinfo.csv" | tr -d ' ') bytes"
  stamp asnames.ipinfo.csv "${key}"
fi

build_go generate-schemas-annotation2 "${UUID_ANNOTATOR_URL}" \
  "${UUID_ANNOTATOR_SCHEMA_VERSION}" cmd/generate-schemas 0

# --- jostler -------------------------------------------------------------------
# Upstream also stamps main.Version (git describe, i.e. the tag) and
# main.GitCommit (the full hash).
build_go jostler https://github.com/m-lab/jostler.git "${JOSTLER_VERSION}" \
  cmd/jostler 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=@COMMIT@ \
   -X main.Version=${JOSTLER_VERSION} \
   -X main.GitCommit=@COMMIT_FULL@"

# --- traceroute-caller (+ traceroute schema generator + scamper) ---------------
TRACEROUTE_URL="https://github.com/m-lab/traceroute-caller.git"
build_go traceroute-caller "${TRACEROUTE_URL}" "${TRACEROUTE_VERSION}" . 0 \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=@COMMIT@"
build_go generate-schemas-traceroute "${TRACEROUTE_URL}" "${TRACEROUTE_VERSION}" \
  cmd/generate-schemas 0

# scamper: build the exact tarball the traceroute-caller image vendors.
# --disable-shared statically links scamper's internal libraries into the
# binary, so the package can ship the single file with no private .so deps.
# OpenSSL is deliberately not linked: configure would silently pick it up if
# the dev headers happen to be installed, making the build host-dependent. The
# image's scamper was built without it, and traceroute-caller does not use the
# TLS probes. There is no --without-openssl switch (AX_CHECK_OPENSSL), so point
# the search at an empty directory instead.
SCAMPER_CONFIGURE_FLAGS="--disable-shared --with-openssl=/nonexistent"
key="$(recipe_key "component=scamper" "dist=${SCAMPER_DIST}" \
  "vendored-in=${TRACEROUTE_VERSION}" "configure=${SCAMPER_CONFIGURE_FLAGS}" \
  "native=${NATIVE_TOOLCHAIN}")"
if needs_build scamper "${key}" scamper; then
  src="$(clone_repo traceroute-caller "${TRACEROUTE_URL}" "${TRACEROUTE_VERSION}")"
  echo ">> building scamper (${SCAMPER_DIST}, vendored in traceroute-caller)"
  scamper_build="${WORK_DIR}/scamper"
  scamper_prefix="${WORK_DIR}/scamper-install"
  mkdir -p "${scamper_build}"
  tar -xzf "${src}/third_party/scamper/${SCAMPER_DIST}.tar.gz" -C "${scamper_build}"
  (
    cd "${scamper_build}/${SCAMPER_DIST}"
    chmod +x ./configure
    # shellcheck disable=SC2086 # deliberate word splitting of the flags
    ./configure --quiet --prefix="${scamper_prefix}" ${SCAMPER_CONFIGURE_FLAGS}
    make --quiet -j"$(nproc)" >/dev/null
    make --quiet install >/dev/null
  )
  install -m 0755 "${scamper_prefix}/bin/scamper" "${OUT_DIR}/scamper"
  check_binary "${OUT_DIR}/scamper"
  stamp scamper "${key}"
fi

# --- autojoin-register ----------------------------------------------------------
build_go autojoin-register https://github.com/m-lab/autojoin.git \
  "${AUTOJOIN_VERSION}" cmd/register 0 \
  "-X main.Version=${AUTOJOIN_VERSION}"

# --- node-exporter ---------------------------------------------------------------
build_go node-exporter https://github.com/prometheus/node_exporter.git \
  "${NODE_EXPORTER_VERSION}" . 0 \
  "-X github.com/prometheus/common/version.Version=${NODE_EXPORTER_VERSION#v} \
   -X github.com/prometheus/common/version.Revision=@COMMIT_FULL@ \
   -X github.com/prometheus/common/version.Branch=HEAD"

echo
echo "Components: ${BUILT} built, ${SKIPPED} cached; staged in ${OUT_DIR}"
