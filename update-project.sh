#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ ${EUID} -eq 0 ]] || die "Hãy chạy bằng sudo: sudo $0 /duong/dan/du-an"
[[ $# -eq 1 ]] || die "Cách dùng: sudo $0 /duong/dan/du-an"
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || die "Cần Docker Compose plugin hoạt động."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$1"
[[ "${PROJECT_DIR}" == /* && -d "${PROJECT_DIR}" && ! -L "${PROJECT_DIR}" ]] || die "Đường dẫn dự án phải là thư mục tuyệt đối, tồn tại và không phải symlink."
PROJECT_DIR="$(realpath -e "${PROJECT_DIR}")"
[[ -f "${PROJECT_DIR}/.env" && -f "${PROJECT_DIR}/compose.yaml" && -f "${PROJECT_DIR}/.project-managed" ]] || die "Không phải dự án mới do installer quản lý. Bản cài cũ cần migrate riêng."

read_env() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${PROJECT_DIR}/.env"
}

PROJECT_SLUG="$(read_env PROJECT_SLUG)"
PROJECT_HOME="$(read_env PROJECT_HOME)"
[[ "${PROJECT_SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "PROJECT_SLUG trong .env không hợp lệ."
[[ "$(cat "${PROJECT_DIR}/.project-managed")" == "${PROJECT_SLUG}" ]] || die "Dấu quản lý không khớp với PROJECT_SLUG."
[[ "${PROJECT_HOME}" == /* && -d "${PROJECT_HOME}" ]] || die "PROJECT_HOME trong .env không hợp lệ."
HOME_REAL="$(realpath -e "${PROJECT_HOME}")"
[[ "${PROJECT_DIR}" == "${HOME_REAL}/"* ]] || die "Dự án không nằm trong PROJECT_HOME đã lưu."

STAMP="$(date '+%Y%m%d-%H%M%S')"
install -d -m 0750 "${PROJECT_DIR}/backups"
BACKUP_DIR="$(mktemp -d "${PROJECT_DIR}/backups/pre-update-${STAMP}-XXXXXX")"
chmod 0750 "${BACKUP_DIR}"
install -d -m 0750 "${BACKUP_DIR}/lib"
cp -a "${PROJECT_DIR}/compose.yaml" "${BACKUP_DIR}/compose.yaml"
[[ -f "${PROJECT_DIR}/manage.sh" ]] && cp -a "${PROJECT_DIR}/manage.sh" "${BACKUP_DIR}/manage.sh"
[[ -f "${PROJECT_DIR}/lib/deploy-common.sh" ]] && cp -a "${PROJECT_DIR}/lib/deploy-common.sh" "${BACKUP_DIR}/lib/deploy-common.sh"
[[ -f "${PROJECT_DIR}/start.sh" ]] && cp -a "${PROJECT_DIR}/start.sh" "${BACKUP_DIR}/start.sh"
[[ -f "${PROJECT_DIR}/stop.sh" ]] && cp -a "${PROJECT_DIR}/stop.sh" "${BACKUP_DIR}/stop.sh"

restore_templates() {
  cp -a "${BACKUP_DIR}/compose.yaml" "${PROJECT_DIR}/compose.yaml"
  [[ ! -f "${BACKUP_DIR}/manage.sh" ]] || cp -a "${BACKUP_DIR}/manage.sh" "${PROJECT_DIR}/manage.sh"
  [[ ! -f "${BACKUP_DIR}/lib/deploy-common.sh" ]] || cp -a "${BACKUP_DIR}/lib/deploy-common.sh" "${PROJECT_DIR}/lib/deploy-common.sh"
  [[ ! -f "${BACKUP_DIR}/start.sh" ]] || cp -a "${BACKUP_DIR}/start.sh" "${PROJECT_DIR}/start.sh"
  [[ ! -f "${BACKUP_DIR}/stop.sh" ]] || cp -a "${BACKUP_DIR}/stop.sh" "${PROJECT_DIR}/stop.sh"
}

STACK_DIR="${PROJECT_DIR}"
source "${SCRIPT_DIR}/lib/deploy-common.sh"

log "Đang cập nhật template cho ${PROJECT_SLUG}; dữ liệu, .env và Tunnel token được giữ nguyên."
install -m 0640 "${SCRIPT_DIR}/compose.yaml" "${PROJECT_DIR}/compose.yaml"
install -d -m 0750 "${PROJECT_DIR}/lib"
cp "${SCRIPT_DIR}/manage-config.sh" "${PROJECT_DIR}/manage.sh"
chmod 0750 "${PROJECT_DIR}/manage.sh"
cp "${SCRIPT_DIR}/lib/deploy-common.sh" "${PROJECT_DIR}/lib/deploy-common.sh"
chmod 0640 "${PROJECT_DIR}/lib/deploy-common.sh"

if ! docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/compose.yaml" \
  -p "${PROJECT_SLUG}" --profile all config --quiet; then
  restore_templates
  die "Cấu hình Compose mới không hợp lệ; đã phục hồi template cũ. Bản lưu: ${BACKUP_DIR}"
fi

if ! docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/compose.yaml" \
  -p "${PROJECT_SLUG}" --profile all pull; then
  restore_templates
  die "Không tải được image; đã phục hồi template cũ. Bản lưu: ${BACKUP_DIR}"
fi

if ! docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/compose.yaml" \
  -p "${PROJECT_SLUG}" --profile all up -d; then
  restore_templates
  die "Khởi chạy sau cập nhật thất bại. Đã phục hồi template cũ; kiểm tra dịch vụ và bản lưu tại ${BACKUP_DIR}."
fi

log "Cập nhật xong. Bản template trước cập nhật được giữ tại ${BACKUP_DIR}."
