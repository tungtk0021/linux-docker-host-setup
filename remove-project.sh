#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }
read_state() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${STATE_FILE}"
}

[[ ${EUID} -eq 0 ]] || die "Hãy chạy bằng sudo: sudo $0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_FILE="${SCRIPT_DIR}/project-state.conf"
if [[ ! -f "${STATE_FILE}" ]]; then
  printf 'Chưa có file project-state.conf; dự án chưa được cài từ thư mục source này.\n'
  exit 0
fi
[[ -t 0 ]] || die "Cần terminal tương tác để chọn thao tác remove."
[[ "$(read_state INSTALL_STATUS)" == installed ]] || die "File trạng thái không hợp lệ; không thực hiện remove."

STACK_DIR="$(read_state STACK_DIR)"
PROJECT_HOME="$(read_state PROJECT_HOME)"
PROJECT_SLUG="$(read_state PROJECT_SLUG)"
STATE_SOURCE_DIR="$(read_state SOURCE_REPO_DIR)"
[[ "${STACK_DIR}" == /* && -d "${STACK_DIR}" && ! -L "${STACK_DIR}" ]] || die "Thư mục dự án trong file trạng thái không tồn tại hoặc không hợp lệ."
[[ "${PROJECT_HOME}" == /* && -d "${PROJECT_HOME}" && ! -L "${PROJECT_HOME}" ]] || die "Home dự án trong file trạng thái không tồn tại hoặc không hợp lệ."
[[ "${PROJECT_SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "PROJECT_SLUG trong file trạng thái không hợp lệ."
[[ -n "${STATE_SOURCE_DIR}" ]] || die "Thiếu SOURCE_REPO_DIR trong file trạng thái."
[[ "$(realpath -e "${STATE_SOURCE_DIR}")" == "${SCRIPT_DIR}" ]] || die "File trạng thái không thuộc thư mục source hiện tại."

STACK_DIR="$(realpath -e "${STACK_DIR}")"
PROJECT_HOME="$(realpath -e "${PROJECT_HOME}")"
[[ "${STACK_DIR}" == "${PROJECT_HOME}/"* && "${STACK_DIR}" != "${PROJECT_HOME}" ]] || die "Thư mục dự án không nằm trong PROJECT_HOME đã lưu."
[[ -f "${STACK_DIR}/.project-managed" && -f "${STACK_DIR}/.env" && -f "${STACK_DIR}/compose.yaml" ]] \
  || die "File trạng thái trỏ đến thư mục thiếu dấu quản lý hoặc cấu hình Compose."
[[ "$(cat "${STACK_DIR}/.project-managed")" == "${PROJECT_SLUG}" ]] || die "Mã dự án trong file trạng thái không khớp dấu quản lý."
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || die "Cần Docker Compose plugin hoạt động."

printf '\nDự án: %s\nThư mục: %s\n' "${PROJECT_SLUG}" "${STACK_DIR}"
printf '1) Dừng và gỡ container, giữ cấu hình và dữ liệu\n'
printf '2) Xóa toàn bộ dự án, dữ liệu, token và backup\n'
printf '3) Mở manage.sh\n0) Thoát\n'
read -r -p 'Chọn thao tác: ' choice

case "${choice}" in
  1)
    docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
      -p "${PROJECT_SLUG}" --profile all down
    printf 'Đã gỡ container. Cấu hình, dữ liệu và file trạng thái được giữ nguyên.\n'
    ;;
  2)
    printf '\nSẼ XÓA VĨNH VIỄN thư mục dự án và toàn bộ dữ liệu tại %s\n' "${STACK_DIR}"
    read -r -p "Gõ WIPE ${PROJECT_SLUG} để xác nhận: " confirmation
    [[ "${confirmation}" == "WIPE ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; exit 0; }
    docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
      -p "${PROJECT_SLUG}" --profile all down
    cd "${PROJECT_HOME}"
    rm -rf --one-file-system -- "${STACK_DIR}"
    rm -f -- "${STATE_FILE}"
    printf 'Đã xóa toàn bộ dự án và file trạng thái.\n'
    ;;
  3)
    exec "${STACK_DIR}/manage.sh"
    ;;
  0)
    printf 'Đã thoát.\n'
    ;;
  *)
    die "Lựa chọn không hợp lệ."
    ;;
esac
