#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ ${EUID} -eq 0 ]] || die "Hãy chạy bằng sudo: sudo $0 /duong/dan/du-an"
[[ $# -ge 1 && $# -le 2 ]] || die "Cách dùng: sudo $0 /duong/dan/du-an [commit-40-ky-tu]"
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
SOURCE_COMMIT="${2:-}"
if [[ -z "${SOURCE_COMMIT}" ]] && command -v git >/dev/null 2>&1; then
  SOURCE_COMMIT="$(git -c safe.directory="${SCRIPT_DIR}" -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi
[[ -z "${SOURCE_COMMIT}" || "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Commit nguồn phải là SHA-1 gồm 40 ký tự hex."
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
write_project_helpers

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
if [[ -n "${SOURCE_COMMIT}" ]]; then
  write_config_value INSTALLED_COMMIT "${SOURCE_COMMIT}"
  log "Đã ghi nhận commit ${SOURCE_COMMIT:0:12} cho lần kiểm tra GitHub tiếp theo."
else
  log "Không đọc được SHA nguồn; lần start sau sẽ kiểm tra lại cập nhật."
fi
