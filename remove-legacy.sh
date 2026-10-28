#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ ${EUID} -eq 0 ]] || die "Hãy chạy bằng sudo: sudo $0"
[[ -t 0 ]] || die "Cần terminal tương tác để xác nhận thao tác."
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || die "Cần Docker Compose plugin hoạt động."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/docker-removal.sh"
list_running_containers

REMOVE_ONLY=0
if [[ "${1:-}" == "--remove-config-only" ]]; then
  [[ $# -eq 2 ]] || die "Cách dùng: sudo $0 --remove-config-only /duong/dan/compose-cu"
  REMOVE_ONLY=1
  PROJECT_DIR="$2"
elif [[ $# -eq 0 ]]; then
  printf '\n1) Tiếp tục gỡ riêng một stack Compose cũ\n'
  printf '2) Gỡ toàn bộ container đang chạy trên máy (giữ volumes và dữ liệu)\n'
  printf '0) Thoát\n'
  read -r -p 'Chọn thao tác: ' TOP_CHOICE
  case "${TOP_CHOICE}" in
    1) ;;
    2) remove_all_running_containers; exit 0 ;;
    0) printf 'Đã thoát.\n'; exit 0 ;;
    *) die "Lựa chọn không hợp lệ." ;;
  esac
  read -r -p "Thư mục Compose cũ [/opt/infra-stack]: " PROJECT_DIR
  PROJECT_DIR="${PROJECT_DIR:-/opt/infra-stack}"
else
  die "Cách dùng: sudo $0 [--remove-config-only /duong/dan/compose-cu]"
fi
[[ "${PROJECT_DIR}" == /* && -d "${PROJECT_DIR}" && ! -L "${PROJECT_DIR}" ]] || die "Thư mục Compose phải là đường dẫn tuyệt đối hợp lệ, không phải symlink."
PROJECT_DIR="$(realpath -e "${PROJECT_DIR}")"
[[ -f "${PROJECT_DIR}/compose.yaml" || -f "${PROJECT_DIR}/compose.yml" \
  || -f "${PROJECT_DIR}/docker-compose.yaml" || -f "${PROJECT_DIR}/docker-compose.yml" ]] \
  || die "Không thấy compose.yaml, compose.yml, docker-compose.yaml hoặc docker-compose.yml trong ${PROJECT_DIR}."
[[ ! -f "${PROJECT_DIR}/.project-managed" ]] || die "Đây là dự án mới do installer quản lý; dùng manage.sh của dự án đó."

COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  for candidate in compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "${PROJECT_DIR}/${candidate}" ]]; then
      COMPOSE_FILE="${PROJECT_DIR}/${candidate}"
      break
    fi
  done
fi
DEFAULT_SLUG="$(basename "${PROJECT_DIR}")"
read -r -p "Tên Compose project cũ [${DEFAULT_SLUG}]: " PROJECT_SLUG
PROJECT_SLUG="${PROJECT_SLUG:-${DEFAULT_SLUG}}"
[[ "${PROJECT_SLUG}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$ ]] || die "Tên Compose project không hợp lệ."

DATA_DIR=""
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  DATA_DIR="$(awk -F= '$1 == "DATA_DIR" { sub(/^[^=]*=/, ""); print; exit }' "${PROJECT_DIR}/.env")"
fi
if [[ -z "${DATA_DIR}" ]]; then
  read -r -p "Đường dẫn DATA_DIR cũ (để trống nếu chưa xác định): " DATA_DIR
fi
if ((REMOVE_ONLY == 0)); then
  printf '\nSẽ dừng và gỡ container thuộc Compose project: %s\n' "${PROJECT_SLUG}"
else
  printf '\nSẽ kiểm tra và chỉ xóa thư mục cấu hình đã dừng của Compose project: %s\n' "${PROJECT_SLUG}"
fi
printf 'Thư mục cấu hình: %s\n' "${PROJECT_DIR}"
printf 'DATA_DIR trong .env: %s\n' "${DATA_DIR:-không khai báo/không xác định}"
if ((REMOVE_ONLY == 0)); then
  printf 'Compose sẽ gỡ các container và network do project này quản lý; external networks và dữ liệu bind mount vẫn được giữ.\n'
  read -r -p "Gõ STOP ${PROJECT_SLUG} để dừng và gỡ container: " CONFIRM_STOP
  [[ "${CONFIRM_STOP}" == "STOP ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; exit 0; }

  docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" \
    -p "${PROJECT_SLUG}" --profile all down
  log "Đã dừng và gỡ container của ${PROJECT_SLUG}. Cấu hình, token, external networks và dữ liệu vẫn còn."
else
  ACTIVE_IDS="$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT_SLUG}")"
  [[ -z "${ACTIVE_IDS}" ]] || die "Vẫn có container mang project label ${PROJECT_SLUG}; không xóa cấu hình. Hãy kiểm tra stack đang chạy."
fi

read -r -p "Có muốn xóa riêng thư mục cấu hình cũ (không xóa DATA_DIR)? [y/N]: " REMOVE_CONFIG
[[ "${REMOVE_CONFIG}" =~ ^([yY]|yes|YES)$ ]] || { printf 'Giữ nguyên thư mục cấu hình và dữ liệu.\n'; exit 0; }

PROJECT_PARENT="$(dirname "${PROJECT_DIR}")"
PROJECT_BASE="$(basename "${PROJECT_DIR}")"
[[ "${PROJECT_DIR}" != / && "${PROJECT_DIR}" != /home && "${PROJECT_DIR}" != /opt && "${PROJECT_DIR}" != /srv ]] || die "Từ chối xóa thư mục gốc hoặc thư mục hệ thống."
if [[ -n "${DATA_DIR}" ]]; then
  if [[ "${DATA_DIR}" == /* ]]; then
    DATA_PATH="${DATA_DIR}"
  else
    DATA_PATH="${PROJECT_DIR}/${DATA_DIR}"
  fi
  DATA_CANON="$(realpath -m -- "${DATA_PATH}")"
  PROJECT_CANON="$(realpath -m -- "${PROJECT_DIR}")"
  [[ "${DATA_CANON}" != "${PROJECT_CANON}" && "${DATA_CANON}" != "${PROJECT_CANON}/"* && "${PROJECT_CANON}" != "${DATA_CANON}/"* ]] \
    || die "DATA_DIR nằm trong hoặc bao phủ thư mục cấu hình; không xóa để tránh xóa nhầm dữ liệu."
else
  die "Không xác định được DATA_DIR. Giữ thư mục cấu hình; hãy kiểm tra các bind mount trước khi xóa thủ công."
fi
printf '\nChỉ xóa thư mục cấu hình: %s\n' "${PROJECT_DIR}"
printf 'Dữ liệu ở %s sẽ được giữ nguyên.\n' "${DATA_DIR:-đường dẫn dữ liệu không xác định}"
read -r -p "Gõ REMOVE CONFIG ${PROJECT_BASE} để xác nhận: " CONFIRM_REMOVE
[[ "${CONFIRM_REMOVE}" == "REMOVE CONFIG ${PROJECT_BASE}" ]] || { printf 'Đã giữ lại thư mục cấu hình.\n'; exit 0; }
cd "${PROJECT_PARENT}"
rm -rf --one-file-system -- "${PROJECT_DIR}"
log "Đã xóa cấu hình cũ. Dữ liệu và Docker networks được giữ lại."
