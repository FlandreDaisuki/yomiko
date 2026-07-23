#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

quality=75
max_dimension=8196
src=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --quality=*)
    quality="${1#*=}"
    shift
    ;;
  --quality)
    if [[ $# -lt 2 ]]; then
      log_err "Missing value for --quality."
      exit 1
    fi
    quality="${2:-}"
    shift 2
    ;;
  --max-dimension=*)
    max_dimension="${1#*=}"
    shift
    ;;
  --max-dimension)
    if [[ $# -lt 2 ]]; then
      log_err "Missing value for --max-dimension."
      exit 1
    fi
    max_dimension="${2:-}"
    shift 2
    ;;
  --)
    shift
    src="${1:-}"
    shift || true
    ;;
  -*)
    log_err "Unknown option: $1"
    exit 1
    ;;
  *)
    src="$1"
    shift
    ;;
  esac
done

if [[ -z "${src}" ]]; then
  log_err "Missing image path."
  exit 1
fi

if [[ ! "${quality}" =~ ^[0-9]+$ ]]; then
  log_err "Invalid WebP quality '${quality}'."
  exit 2
fi

if [[ ! "${max_dimension}" =~ ^[0-9]+$ || "${max_dimension}" -le 0 ]]; then
  log_err "Invalid max dimension '${max_dimension}'."
  exit 3
fi

out="${src%.*}.webp"
tmp="${out}.tmp.$$"
magick_stderr=""
trap 'rm -f "${tmp}" "${magick_stderr:-}"' EXIT

magick_args=(
  -limit memory "${MAGICK_MEMORY_LIMIT:-256MiB}"
  -limit map "${MAGICK_MAP_LIMIT:-256MiB}"
  -limit thread "${MAGICK_THREAD_LIMIT:-1}"
  "${src}"
  -resize "${max_dimension}x${max_dimension}>"
  -quality "${quality}"
  "webp:${tmp}"
)

if yomiko_in_api_mode; then
  magick_stderr="${tmp}.magick.stderr"
  if ! magick "${magick_args[@]}" 2>"${magick_stderr}"; then
    exit 4
  fi
else
  if ! magick "${magick_args[@]}"; then
    log_err "Failed to convert image: ${src}"
    exit 4
  fi
fi

mv -f "${tmp}" "${out}"
trap - EXIT
