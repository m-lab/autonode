#!/bin/bash
#
# build-binaries.sh builds the component binaries from source at the upstream
# release tags pinned below and stages them under ./binaries/ so they can be
# shipped in the mlab-node Debian package. Building from source (rather than
# extracting binaries from the released container images) gives verifiable
# provenance — git tag + go.sum + the Go checksum database — and produces
# glibc-compatible binaries by construction, with no Docker or image tooling
# involved at any point.
#
# Required host tools (build-time only): git, go, gcc, make, file.
# The build host must be linux on amd64 or arm64; the binaries (Go and the
# vendored scamper C code) are compiled natively for the host architecture,
# which is also the architecture of the resulting package.
#
# Every Go component builds with CGO_ENABLED=0 (static) except ndt-server and
# its schema generator: ndt-server's bbr package requires cgo on Linux, so
# those two build with CGO_ENABLED=1 and come out glibc-dynamic (fine on the
# Debian target; dh_shlibdeps declares the libc dependency). The Go toolchain
# is pinned (GOTOOLCHAIN below) so builds do not depend on the build host's go
# version; the pinned toolchain is fetched on demand by the system go. Version
# ldflags mirror what each upstream image build stamps, so Prometheus
# build-info metrics keep reporting versions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/binaries"

# Component versions. These mirror the image tags pinned in the historical
# docker-compose deployment, so the package builds the exact sources M-Lab has
# tested.
# NOTE: heartbeat lives in the m-lab/locate repository (cmd/heartbeat); the
# measurementlab/heartbeat image tags track locate's tags.
# NOTE: the annotation2 schema generator intentionally comes from an older
# uuid-annotator tag (v0.5.8) than the running annotator (v0.5.10), matching
# the compose configuration.
VER_NDT_SERVER="v0.25.3"
VER_HEARTBEAT="v0.19.1"
VER_UUID_ANNOTATOR="v0.5.10"
VER_UUID_ANNOTATOR_SCHEMA="v0.5.8"
VER_JOSTLER="v1.1.4"
VER_TRACEROUTE="v0.12.0"
VER_AUTOJOIN="v0.2.13"
VER_NODE_EXPORTER="v1.9.0"

# scamper is C, not Go; traceroute-caller vendors the exact snapshot it is
# tested against, so we build that tarball rather than Debian's scamper.
SCAMPER_SNAPSHOT="scamper-cvs-20230302"

# Pinned Go toolchain used for every component. Newer toolchains build older
# modules fine (Go 1 compatibility); pinning one version keeps builds
# deterministic across build hosts. It must also satisfy the highest `go`
# directive among the pinned sources (ndt-server's bare "go 1.25" otherwise
# mis-resolves to a non-existent "go1.25" toolchain download on older hosts).
GO_TOOLCHAIN="go1.25.11"

for tool in git go gcc make file; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: required build tool '${tool}' not found in PATH" >&2
    exit 1
  }
done

case "$(uname -sm)" in
  "Linux x86_64"|"Linux aarch64") ;;
  *)
    echo "ERROR: this script must run on a linux amd64/arm64 build host (got: $(uname -sm))" >&2
    exit 1
    ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Hermetic Go state: do not touch (or depend on) the build host's module
# cache. CGO is disabled by default (overridden per-build where required);
# -trimpath aids reproducibility.
export CGO_ENABLED=0
export GOTOOLCHAIN="${GO_TOOLCHAIN}"
export GOPATH="${WORK_DIR}/gopath"
export GOCACHE="${WORK_DIR}/gocache"
export GOFLAGS="-trimpath"

# clone_at_tag URL TAG DEST — shallow clone of a repo at a release tag.
# The clone (not a tarball download) provides the commit hash for version
# stamping and, for traceroute-caller, the vendored scamper tarball.
clone_at_tag() {
  local url="$1" tag="$2" dest="$3"
  [ -d "${dest}" ] && return 0
  echo ">> cloning ${url}@${tag}"
  git clone --quiet --depth 1 --branch "${tag}" "${url}" "${dest}"
}

# short_commit DIR — abbreviated hash of the checked-out commit, as upstream
# image builds pass to -X github.com/m-lab/go/prometheusx.GitShortCommit.
short_commit() {
  git -C "$1" log -1 --format=%h
}

# build_go SRC_DIR REL_PKG_DIR OUT_NAME [LDFLAGS]
# Builds the main package at SRC_DIR/REL_PKG_DIR into OUT_DIR/OUT_NAME.
# Building from within the package directory transparently handles both
# regular packages and nested Go modules (ndt-server's cmd/generate-schemas).
# Respects CGO_ENABLED from the environment (0 by default, see above).
build_go() {
  local src="$1" rel="$2" out="$3" ldflags="${4:-}"
  echo ">> building ${out} from ${src##*/}/${rel#.} (CGO_ENABLED=${CGO_ENABLED})"
  (
    cd "${src}/${rel}"
    go build ${ldflags:+-ldflags "${ldflags}"} -o "${OUT_DIR}/${out}" .
  )
  check_binary "${OUT_DIR}/${out}"
}

# check_binary PATH — the Go binaries must be static ELF executables; scamper
# is glibc-dynamic (dh_shlibdeps resolves its shared-lib deps). Anything that
# is not ELF is fatal.
check_binary() {
  local bin="$1" info
  info="$(file -L "${bin}")"
  case "${info}" in
    *"ELF"*) ;;
    *)
      echo "ERROR: ${bin} does not look like an ELF executable: ${info}" >&2
      exit 1
      ;;
  esac
  echo "   ${bin##*/}: ${info#*: }"
}

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

SRC="${WORK_DIR}/src"
clone_at_tag https://github.com/m-lab/ndt-server.git         "${VER_NDT_SERVER}"            "${SRC}/ndt-server"
clone_at_tag https://github.com/m-lab/locate.git             "${VER_HEARTBEAT}"             "${SRC}/locate"
clone_at_tag https://github.com/m-lab/uuid-annotator.git     "${VER_UUID_ANNOTATOR}"        "${SRC}/uuid-annotator"
clone_at_tag https://github.com/m-lab/uuid-annotator.git     "${VER_UUID_ANNOTATOR_SCHEMA}" "${SRC}/uuid-annotator-schema"
clone_at_tag https://github.com/m-lab/jostler.git            "${VER_JOSTLER}"               "${SRC}/jostler"
clone_at_tag https://github.com/m-lab/traceroute-caller.git  "${VER_TRACEROUTE}"            "${SRC}/traceroute-caller"
clone_at_tag https://github.com/m-lab/autojoin.git           "${VER_AUTOJOIN}"              "${SRC}/autojoin"
clone_at_tag https://github.com/prometheus/node_exporter.git "${VER_NODE_EXPORTER}"         "${SRC}/node_exporter"

# Per-component ldflags replicate each upstream image build (see the
# Dockerfiles at the pinned tags); without them the binaries report empty
# versions in logs and Prometheus build-info metrics.
#
# ndt-server (and its schema generator, which imports the same packages)
# requires cgo for the bbr package: with CGO_ENABLED=0 the build fails with
# "undefined: enableBBR".
CGO_ENABLED=1 build_go "${SRC}/ndt-server" . ndt-server \
  "-X github.com/m-lab/ndt-server/version.Version=${VER_NDT_SERVER} -X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${SRC}/ndt-server")"
CGO_ENABLED=1 build_go "${SRC}/ndt-server" cmd/generate-schemas generate-schemas-ndt7

build_go "${SRC}/locate" cmd/heartbeat heartbeat \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${SRC}/locate")"

build_go "${SRC}/uuid-annotator" . uuid-annotator \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${SRC}/uuid-annotator")"
build_go "${SRC}/uuid-annotator-schema" cmd/generate-schemas generate-schemas-annotation2

build_go "${SRC}/jostler" cmd/jostler jostler \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${SRC}/jostler") -X main.Version=${VER_JOSTLER} -X main.GitCommit=$(git -C "${SRC}/jostler" log -1 --format=%H)"

build_go "${SRC}/traceroute-caller" . traceroute-caller \
  "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(short_commit "${SRC}/traceroute-caller")"
build_go "${SRC}/traceroute-caller" cmd/generate-schemas generate-schemas-traceroute

build_go "${SRC}/autojoin" cmd/register autojoin-register \
  "-s -w -X main.Version=${VER_AUTOJOIN}"

build_go "${SRC}/node_exporter" . node-exporter \
  "-X github.com/prometheus/common/version.Version=${VER_NODE_EXPORTER#v} -X github.com/prometheus/common/version.Revision=$(git -C "${SRC}/node_exporter" log -1 --format=%H) -X github.com/prometheus/common/version.Branch=HEAD"

# Build scamper from the snapshot vendored in traceroute-caller. The tarball
# ships a pre-generated ./configure (no autotools needed); --disable-shared
# links scamper's internal libraries statically so we ship a single
# self-contained binary (only libc is dynamic).
echo ">> building scamper from vendored ${SCAMPER_SNAPSHOT}"
tar -xzf "${SRC}/traceroute-caller/third_party/scamper/${SCAMPER_SNAPSHOT}.tar.gz" -C "${WORK_DIR}"
(
  cd "${WORK_DIR}/${SCAMPER_SNAPSHOT}"
  chmod +x ./configure
  ./configure --disable-shared --prefix="${WORK_DIR}/scamper-prefix" >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
)
install -m 0755 "${WORK_DIR}/scamper-prefix/bin/scamper" "${OUT_DIR}/scamper"
check_binary "${OUT_DIR}/scamper"

# Ship the IPInfo AS-names CSV from the uuid-annotator repo. The container
# image passes it to the binary via `ENV ASNAME_URL file:///data/...`; systemd
# does not inherit image ENVs, so we ship the same file and pass it via
# -asname.url.
install -m 0644 "${SRC}/uuid-annotator/data/asnames.ipinfo.csv" "${OUT_DIR}/asnames.ipinfo.csv"
echo "   asnames.ipinfo.csv: $(wc -c <"${OUT_DIR}/asnames.ipinfo.csv" | tr -d ' ') bytes"

echo
echo "Staged $(ls -1 "${OUT_DIR}" | wc -l | tr -d ' ') artifacts in ${OUT_DIR}"
