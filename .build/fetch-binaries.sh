#!/bin/bash
#
# fetch-binaries.sh extracts the component binaries from the pinned M-Lab
# container images and stages them under ./binaries/ so they can be shipped in
# the mlab-node Debian package. It uses skopeo to pull the image filesystems
# without a running Docker daemon: no Docker is required to build the package,
# and none is required at runtime.
#
# Required host tools (build-time only): skopeo, jq, tar, file.
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

# extraction requests: "image|search-names|dest-name"
# search-names is a comma-separated list of candidate basenames to locate in the
# image rootfs (first match wins), to tolerate differing install paths.
REQUESTS=(
  "${IMG_NDT_SERVER}|ndt-server|ndt-server"
  "${IMG_NDT_SERVER}|generate-schemas|generate-schemas-ndt7"
  "${IMG_HEARTBEAT}|heartbeat|heartbeat"
  "${IMG_UUID_ANNOTATOR}|uuid-annotator|uuid-annotator"
  "${IMG_UUID_ANNOTATOR_SCHEMA}|generate-schemas|generate-schemas-annotation2"
  "${IMG_JOSTLER}|jostler|jostler"
  "${IMG_TRACEROUTE}|traceroute-caller|traceroute-caller"
  "${IMG_TRACEROUTE}|generate-schemas|generate-schemas-traceroute"
  "${IMG_TRACEROUTE}|scamper|scamper"
  "${IMG_REGISTER}|register,autojoin-register|autojoin-register"
  "${IMG_NODE_EXPORTER}|node_exporter,node-exporter|node-exporter"
)

for tool in skopeo jq tar file; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: required build tool '${tool}' not found in PATH" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# unpack_image IMAGE DEST_ROOTFS
# Copies the image to a local OCI/dir layout with skopeo and extracts every
# layer (in manifest order) into DEST_ROOTFS to reconstruct the image rootfs.
declare -A UNPACKED=()
unpack_image() {
  local image="$1" rootfs="$2"
  local imgdir="${WORK_DIR}/img/$(echo "${image}" | tr '/:' '__')"

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

# check_binary PATH — abort if the ELF is musl-linked (won't run on Debian).
check_binary() {
  local bin="$1" info
  info="$(file -L "${bin}")"
  case "${info}" in
    *"statically linked"*) ;;                       # portable, OK
    *"dynamically linked"*)
      if echo "${info}" | grep -q "ld-musl"; then
        echo "ERROR: ${bin} is musl-linked (Alpine); it will not run on Debian." >&2
        echo "       Build this component from source or use a Debian package instead." >&2
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
  IFS='|' read -r image names dest <<<"${req}"
  rootfs="${WORK_DIR}/rootfs/$(echo "${image}" | tr '/:' '__')"
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

  install -D -m 0755 "${found}" "${OUT_DIR}/${dest}"
  check_binary "${OUT_DIR}/${dest}"
done

echo
echo "Staged $(ls -1 "${OUT_DIR}" | wc -l | tr -d ' ') binaries in ${OUT_DIR}"
