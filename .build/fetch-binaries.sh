#!/bin/bash
#
# fetch-binaries.sh extracts the component binaries from the pinned M-Lab
# container images and stages them under ./binaries/ so they can be shipped in
# the mlab-node Debian package. It uses skopeo to pull the image filesystems
# without a running Docker daemon: no Docker is required to build the package,
# and none is required at runtime.
#
# Required host tools (build-time only): skopeo, jq, tar, file, go, git.
#
# The binaries are version-pinned to the same image tags used by the historical
# docker-compose deployment, so the package ships the exact binaries M-Lab has
# tested. Each extracted ELF is checked: a statically linked or glibc-linked
# binary is fine on Debian; a musl-linked (Alpine) binary is NOT and aborts the
# build, because it would fail to run on the target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/binaries"

# The staged tree is fresh only if it was produced by this exact script
# (the version pins live in it): the stamp records the script's hash and is
# written only after a fully successful run. Editing the script (e.g. bumping
# a pinned tag) or an interrupted fetch invalidates it.
STAMP_FILE="${OUT_DIR}/.fetch-stamp"
SCRIPT_HASH="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
if [ "$(cat "${STAMP_FILE}" 2>/dev/null)" = "${SCRIPT_HASH}" ]; then
  echo "binaries/ already staged by this script version; skipping fetch"
  exit 0
fi

# Image versions. These mirror the tags pinned in the original docker-compose.yml.
# NOTE: the annotation2 schema generator intentionally comes from an older
# uuid-annotator image (v0.5.8) than the running annotator (v0.5.10), matching
# the compose configuration.
IMG_NDT_SERVER="measurementlab/ndt-server:v0.25.2"
IMG_HEARTBEAT="measurementlab/heartbeat:v0.19.1"
IMG_UUID_ANNOTATOR="measurementlab/uuid-annotator:v0.5.10"
IMG_UUID_ANNOTATOR_SCHEMA="measurementlab/uuid-annotator:v0.5.8"
IMG_JOSTLER="measurementlab/jostler:v1.1.4"
IMG_TRACEROUTE="measurementlab/traceroute-caller:v0.12.0"
IMG_REGISTER="measurementlab/autojoin-register:v0.2.13"
IMG_NODE_EXPORTER="quay.io/prometheus/node-exporter:v1.9.0"

# generate-schemas-ndt7 is built from source rather than extracted: the
# ndt-server image builds it on Alpine with CGO (musl-dev), so the shipped copy
# is musl-linked. We rebuild the same pinned source with CGO on the glibc build
# host, yielding a glibc-dynamic binary (NEEDED: libc.so.6) that runs natively.
# NDT_GO_TOOLCHAIN must satisfy the `go` directive in that version's go.mod; the
# system go fetches it on demand (the bare "go 1.25" directive otherwise mis-
# resolves to a non-existent "go1.25" download).
NDT_SERVER_SRC="https://github.com/m-lab/ndt-server.git"
NDT_SERVER_VERSION="${IMG_NDT_SERVER##*:}"
NDT_GO_TOOLCHAIN="go1.25.11"

# extraction requests: "image|search-names|dest-name|type"
# search-names is a comma-separated list of candidate basenames to locate in the
# image rootfs (first match wins), to tolerate differing install paths. type is
# "bin" (installed 0755, ELF-checked) or "data" (installed 0644, unchecked).
REQUESTS=(
  "${IMG_NDT_SERVER}|ndt-server|ndt-server|bin"
  "${IMG_HEARTBEAT}|heartbeat|heartbeat|bin"
  "${IMG_UUID_ANNOTATOR}|uuid-annotator|uuid-annotator|bin"
  "${IMG_UUID_ANNOTATOR_SCHEMA}|generate-schemas|generate-schemas-annotation2|bin"
  "${IMG_JOSTLER}|jostler|jostler|bin"
  "${IMG_TRACEROUTE}|traceroute-caller|traceroute-caller|bin"
  "${IMG_TRACEROUTE}|generate-schemas|generate-schemas-traceroute|bin"
  "${IMG_TRACEROUTE}|scamper|scamper|bin"
  "${IMG_REGISTER}|register,autojoin-register|autojoin-register|bin"
  "${IMG_NODE_EXPORTER}|node_exporter,node-exporter|node-exporter|bin"
  # The IPInfo AS-names CSV bundled in the uuid-annotator image. The image
  # provides it via `ENV ASNAME_URL file:///data/asnames.ipinfo.csv`, which the
  # binary reads through flagx.ArgsFromEnv (asname.url <- ASNAME_URL). systemd
  # does not inherit image ENVs, so we ship the file and pass it via -asname.url.
  "${IMG_UUID_ANNOTATOR}|asnames.ipinfo.csv|asnames.ipinfo.csv|data"
)

for tool in skopeo jq tar file go git; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: required build tool '${tool}' not found in PATH" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d)"
# Image layers can contain root-owned, mode-000 entries (e.g. var/empty); make
# the tree writable before removing it so cleanup never fails the script.
trap 'chmod -R u+rwX "${WORK_DIR}" 2>/dev/null || true; rm -rf "${WORK_DIR}" 2>/dev/null || true' EXIT

# mangle IMAGE — filesystem-safe directory name for an image reference.
mangle() { echo "$1" | tr '/:' '__'; }

# unpack_image IMAGE DEST_ROOTFS
# Copies the image to a local OCI/dir layout with skopeo and extracts every
# layer (in manifest order) into DEST_ROOTFS to reconstruct the image rootfs.
declare -A UNPACKED=()
unpack_image() {
  local image="$1" rootfs="$2"
  local imgdir="${WORK_DIR}/img/$(mangle "${image}")"

  if [ -n "${UNPACKED[${image}]:-}" ]; then
    return 0
  fi

  echo ">> pulling ${image}"
  mkdir -p "${imgdir}" "${rootfs}"
  # Force a single linux/amd64 instance so the dir: manifest is an image
  # manifest (with .layers) even when the source is a multi-arch index.
  skopeo --override-os linux --override-arch amd64 \
    copy --quiet "docker://${image}" "dir:${imgdir}"

  # Layer blobs are listed (in order) in the manifest; each is a gzipped tar.
  local layer
  while read -r layer; do
    local blob="${imgdir}/${layer#sha256:}"
    [ -f "${blob}" ] || { echo "ERROR: missing layer blob ${blob}" >&2; exit 1; }
    # Extract over the rootfs; ignore whiteout/permission quirks (we only need
    # to read out a handful of executables afterwards).
    tar -xf "${blob}" -C "${rootfs}" 2>/dev/null || true
  done < <(jq -r '.layers[].digest' "${imgdir}/manifest.json")

  UNPACKED[${image}]=1
}

# check_binary PATH — classify the ELF. glibc-dynamic and static binaries run on
# Debian as-is (dh_shlibdeps resolves shared-lib deps). A musl-linked (Alpine)
# binary would not run on the target, so it aborts the build; rebuild such
# outliers from source instead (see generate-schemas-ndt7 below). A non-ELF
# file is fatal too.
check_binary() {
  local bin="$1" info
  info="$(file -L "${bin}")"
  case "${info}" in
    *"statically linked"*) ;;                       # portable, OK
    *"dynamically linked"*)
      if echo "${info}" | grep -q "ld-musl"; then
        echo "ERROR: ${bin##*/} is musl-linked and would not run on the target;" >&2
        echo "       rebuild it from source instead (see generate-schemas-ndt7)." >&2
        exit 1
      fi
      ;;                                            # glibc dynamic, OK (dh_shlibdeps handles deps)
    *"ELF"*) ;;
    *)
      echo "ERROR: ${bin} does not look like an executable: ${info}" >&2
      exit 1
      ;;
  esac
  echo "   ${bin##*/}: ${info#*: }"
}

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

for req in "${REQUESTS[@]}"; do
  IFS='|' read -r image names dest type <<<"${req}"
  rootfs="${WORK_DIR}/rootfs/$(mangle "${image}")"
  unpack_image "${image}" "${rootfs}"

  found=""
  IFS=',' read -ra candidates <<<"${names}"
  for name in "${candidates[@]}"; do
    # Prefer an executable regular file; search the whole rootfs.
    found="$(find "${rootfs}" -type f -name "${name}" -perm -u+x 2>/dev/null | head -n1 || true)"
    [ -z "${found}" ] && found="$(find "${rootfs}" -type f -name "${name}" 2>/dev/null | head -n1 || true)"
    [ -n "${found}" ] && break
  done

  if [ -z "${found}" ]; then
    echo "ERROR: could not find any of [${names}] in ${image}" >&2
    exit 1
  fi

  if [ "${type}" = "bin" ]; then
    install -D -m 0755 "${found}" "${OUT_DIR}/${dest}"
    check_binary "${OUT_DIR}/${dest}"
  else
    install -D -m 0644 "${found}" "${OUT_DIR}/${dest}"
    echo "   ${dest}: $(wc -c <"${OUT_DIR}/${dest}" | tr -d ' ') bytes"
  fi
done

# Build generate-schemas-ndt7 from source (glibc-dynamic, CGO on), since the
# ndt-server image ships it musl-linked. cmd/generate-schemas is a nested Go
# module inside the ndt-server repo, so build from within that directory.
echo ">> building generate-schemas-ndt7 from ${NDT_SERVER_SRC}@${NDT_SERVER_VERSION}"
SRC_DIR="${WORK_DIR}/ndt-server"
git clone --quiet --depth 1 --branch "${NDT_SERVER_VERSION}" "${NDT_SERVER_SRC}" "${SRC_DIR}"
(
  cd "${SRC_DIR}/cmd/generate-schemas"
  CGO_ENABLED=1 \
  GOTOOLCHAIN="${NDT_GO_TOOLCHAIN}" \
  GOPATH="${WORK_DIR}/go" \
  GOCACHE="${WORK_DIR}/gocache" \
    go build -trimpath -o "${OUT_DIR}/generate-schemas-ndt7" .
)
check_binary "${OUT_DIR}/generate-schemas-ndt7"

printf '%s\n' "${SCRIPT_HASH}" > "${STAMP_FILE}"
echo
echo "Staged $(ls -1 "${OUT_DIR}" | wc -l | tr -d ' ') artifacts in ${OUT_DIR}"
