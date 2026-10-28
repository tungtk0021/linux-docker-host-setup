#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }
read_config() {
  local file="$1" key="$2"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${file}"
}

[[ ${EUID} -eq 0 ]] || die "Hãy chạy bằng sudo: sudo $0"
[[ -t 0 ]] || die "Cần terminal tương tác để chọn thao tác remove."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GLOBAL_CONFIG="${SCRIPT_DIR}/global-config.conf"
if [[ ! -f "${GLOBAL_CONFIG}" ]]; then
  printf 'Chưa có global-config.conf; chưa có dự án được đăng ký từ source này.\n'
  exit 0
fi

mapfile -t PROJECTS < <(awk -F= '/^PROJECT=/ { sub(/^PROJECT=/, ""); print }' "${GLOBAL_CONFIG}")
(("${#PROJECTS[@]}" > 0)) || { printf 'Global config chưa có dự án nào được cài.\n'; exit 0; }
printf 'Các dự án đã đăng ký:\n'
for i in "${!PROJECTS[@]}"; do
  entry="${PROJECTS[$i]}"
  project_dir="${entry%%|*}"
  printf '%d) %s\n' "$((i + 1))" "${project_dir#PROJECT=}"
done
read -r -p 'Chọn số dự án: ' selected
[[ "${selected}" =~ ^[0-9]+$ ]] || die "Lựa chọn không hợp lệ."
index="$((selected - 1))"
((index >= 0 && index < ${#PROJECTS[@]})) || die "Số dự án không tồn tại."

entry="${PROJECTS[$index]}"
STACK_DIR="${entry#PROJECT=}"
STACK_DIR="${STACK_DIR%%|*}"
CONFIG_FILE="${entry#*|}"
[[ "${CONFIG_FILE}" == "${STACK_DIR}/project-config.conf" ]] || die "Đường dẫn file cấu hình trong global config không hợp lệ."
[[ -f "${CONFIG_FILE}" ]] || die "Không tìm thấy file cấu hình dự án: ${CONFIG_FILE}"
[[ "${STACK_DIR}" == /* && -d "${STACK_DIR}" && ! -L "${STACK_DIR}" ]] || die "Thư mục dự án không tồn tại hoặc không hợp lệ."

PROJECT_HOME="$(read_config "${CONFIG_FILE}" PROJECT_HOME)"
PROJECT_SLUG="$(read_config "${CONFIG_FILE}" PROJECT_SLUG)"
[[ "${PROJECT_HOME}" == /* && -d "${PROJECT_HOME}" && ! -L "${PROJECT_HOME}" ]] || die "PROJECT_HOME trong file cấu hình không hợp lệ."
[[ "${PROJECT_SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "PROJECT_SLUG trong file cấu hình không hợp lệ."
STACK_DIR="$(realpath -e "${STACK_DIR}")"
PROJECT_HOME="$(realpath -e "${PROJECT_HOME}")"
[[ "${STACK_DIR}" == "${PROJECT_HOME}/"* && "${STACK_DIR}" != "${PROJECT_HOME}" ]] || die "Thư mục dự án không nằm dưới PROJECT_HOME."
[[ -f "${STACK_DIR}/.project-managed" && -f "${STACK_DIR}/.env" && -f "${STACK_DIR}/compose.yaml" ]] \
  || die "Thư mục dự án thiếu dấu quản lý hoặc cấu hình Compose."
[[ "$(cat "${STACK_DIR}/.project-managed")" == "${PROJECT_SLUG}" ]] || die "Mã dự án không khớp dấu quản lý."
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
    printf 'Đã gỡ container. Cấu hình, dữ liệu và đăng ký global được giữ nguyên.\n'
    ;;
  2)
    printf '\nSẼ XÓA VĨNH VIỄN thư mục dự án và toàn bộ dữ liệu tại %s\n' "${STACK_DIR}"
    read -r -p "Gõ WIPE ${PROJECT_SLUG} để xác nhận: " confirmation
    [[ "${confirmation}" == "WIPE ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; exit 0; }
    [[ "${SCRIPT_DIR}" != "${STACK_DIR}" && "${SCRIPT_DIR}" != "${STACK_DIR}/"* ]] \
      || die "Không xóa dự án vì source repo đang nằm bên trong thư mục đó."
    docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
      -p "${PROJECT_SLUG}" --profile all down
    cd "${PROJECT_HOME}"
    rm -rf --one-file-system -- "${STACK_DIR}"
    tmp="$(mktemp "${GLOBAL_CONFIG}.tmp.XXXXXX")"
    awk -F'|' -v target="PROJECT=${STACK_DIR}" '$0 !~ /^PROJECT=/ || $1 != target { print }' "${GLOBAL_CONFIG}" > "${tmp}"
    chown root:root "${tmp}"
    chmod 0600 "${tmp}"
    mv -f "${tmp}" "${GLOBAL_CONFIG}"
    printf 'Đã xóa dự án và gỡ dự án khỏi global-config.conf.\n'
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
