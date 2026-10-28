#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

STACK_DIR="${STACK_DIR:-}"
TOKEN_FILE="${TOKEN_FILE:-}"
PROJECT_HOME="${PROJECT_HOME:-}"
PROJECT_RELATIVE_DIR="${PROJECT_RELATIVE_DIR:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_SLUG="${PROJECT_SLUG:-}"
DATA_DIR="${DATA_DIR:-}"
EDGE_NETWORK="${EDGE_NETWORK:-}"
APP_NETWORK="${APP_NETWORK:-}"
EDGE_SUBNET="${EDGE_SUBNET:-}"
APP_SUBNET="${APP_SUBNET:-}"
UPDATE_REPO="${UPDATE_REPO:-https://github.com/tungtk0021/ubuntu-deploy}"
UPDATE_BRANCH="${UPDATE_BRANCH:-main}"
INSTALLED_COMMIT="${INSTALLED_COMMIT:-}"
TUNNEL_ENABLED="${TUNNEL_ENABLED:-}"
readonly SECRET_GROUP="cloudflared-secret"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'LỖI: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Cài Docker, Nginx Proxy Manager, Portainer CE và Cloudflare Tunnel.

Cách dùng:
  sudo ./deploy-ubuntu.sh
  sudo ./deploy-debian.sh

Tùy chọn qua biến môi trường:
  PROJECT_HOME    Home chứa dự án (mặc định home của người gọi sudo)
  EDGE_SUBNET     Docker network cho Tunnel/NPM/Portainer (10.1.1.0/24)
  APP_SUBNET      Docker network cho ứng dụng (10.1.2.0/24)

Không truyền Cloudflare Tunnel token qua command line hoặc biến môi trường.
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Hãy chạy script bằng sudo hoặc tài khoản root."
  command -v apt-get >/dev/null 2>&1 || die "Chỉ hỗ trợ hệ Debian/Ubuntu dùng APT."
  command -v systemctl >/dev/null 2>&1 || die "Không tìm thấy systemd; script yêu cầu máy chủ dùng systemd."
  local cmd missing=()
  for cmd in dpkg dpkg-query realpath awk sed cut tr head install mktemp getent groupadd chown chmod basename dirname date cat mkdir cp mv rm find; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  ((${#missing[@]} == 0)) || die "Thiếu lệnh hệ thống: ${missing[*]}. Trên Ubuntu/Debian Minimal, thử: sudo apt-get update && sudo apt-get install -y coreutils mawk sed passwd libc-bin dpkg findutils."
  realpath -m / >/dev/null 2>&1 || die "Lệnh realpath không hỗ trợ tùy chọn -m; hãy cập nhật gói coreutils của hệ điều hành."
}

check_os() {
  local expected="$1"
  [[ -r /etc/os-release ]] || die "Không đọc được /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${expected}:${ID:-}" in
    ubuntu:ubuntu)
      case "${VERSION_ID:-}" in
        22.04|24.04|26.04) ;;
        *) die "Ubuntu ${VERSION_ID:-unknown} chưa nằm trong danh sách hỗ trợ; dùng Ubuntu LTS 22.04, 24.04 hoặc 26.04." ;;
      esac
      REPO_DISTRO=ubuntu
      ;;
    debian:debian)
      case "${VERSION_ID:-}" in
        12|13) ;;
        *) die "Debian ${VERSION_ID:-unknown} chưa nằm trong danh sách hỗ trợ; dùng Debian 12 hoặc 13." ;;
      esac
      REPO_DISTRO=debian
      ;;
    *) die "Script này dành cho ${expected}; hệ thống hiện tại là ${PRETTY_NAME:-${ID:-unknown}}." ;;
  esac

  ARCH="$(dpkg --print-architecture)"
  case "${ARCH}" in
    amd64|arm64) ;;
    *) die "Kiến trúc ${ARCH} chưa nằm trong phạm vi image dịch vụ được ghim; hiện hỗ trợ amd64 và arm64." ;;
  esac

  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "${CODENAME}" ]] || die "Không xác định được codename của hệ điều hành."
}

choose_project_location() {
  [[ -t 0 ]] || die "Cần chạy tương tác để chọn tên và vị trí thư mục dự án."
  local caller="${SUDO_USER:-root}" caller_home default_slug default_name saved_slug saved_home part home_real resolved_target walk marker default_relative candidate
  local -a managed_markers=() parts=()
  caller_home="$(getent passwd "${caller}" | cut -d: -f6)"
  caller_home="${caller_home:-/root}"
  PROJECT_HOME="${PROJECT_HOME:-${caller_home}}"
  [[ "${PROJECT_HOME}" == /* && -d "${PROJECT_HOME}" && ! -L "${PROJECT_HOME}" ]] || die "PROJECT_HOME phải là thư mục home tuyệt đối đã tồn tại và không phải symlink."
  default_slug="${PROJECT_SLUG:-docker-infra}"
  home_real="$(realpath -e "${PROJECT_HOME}")"
  default_relative="${PROJECT_RELATIVE_DIR:-${PROJECT_SLUG:-${default_slug}}}"
  if [[ -z "${PROJECT_RELATIVE_DIR:-}" && -z "${PROJECT_SLUG:-}" && ! -e "${PROJECT_HOME}/${default_relative}" ]]; then
    mapfile -t managed_markers < <(find "${home_real}" -mindepth 2 -maxdepth 4 -type f -name .project-managed -print 2>/dev/null)
    if ((${#managed_markers[@]} == 1)); then
      candidate="${managed_markers[0]%/.project-managed}"
      if [[ "${candidate}" == "${home_real}/"* ]]; then
        default_relative="${candidate#"${home_real}/"}"
      fi
    fi
  fi
  read -r -p "Home dự án [${PROJECT_HOME}]: " entered_home
  PROJECT_HOME="${entered_home:-${PROJECT_HOME}}"
  [[ "${PROJECT_HOME}" == /* && -d "${PROJECT_HOME}" && ! -L "${PROJECT_HOME}" ]] || die "Home dự án phải là thư mục tuyệt đối đã tồn tại và không phải symlink."
  read -r -p "Đường dẫn thư mục dự án bên trong home [${default_relative}]: " entered_relative
  PROJECT_RELATIVE_DIR="${entered_relative:-${default_relative}}"
  [[ "${PROJECT_RELATIVE_DIR}" != /* && "${PROJECT_RELATIVE_DIR}" != *:* && "${PROJECT_RELATIVE_DIR}" != *[[:space:]]* ]] || die "Đường dẫn dự án phải tương đối, không có khoảng trắng hoặc dấu hai chấm."
  IFS=/ read -ra parts <<< "${PROJECT_RELATIVE_DIR}"
  for part in "${parts[@]}"; do [[ -n "${part}" && "${part}" != . && "${part}" != .. ]] || die "Đường dẫn dự án không được chứa thành phần rỗng, . hoặc .."; done
  STACK_DIR="${PROJECT_HOME}/${PROJECT_RELATIVE_DIR}"
  home_real="$(realpath -e "${PROJECT_HOME}")"
  resolved_target="$(realpath -m -- "${STACK_DIR}")"
  [[ "${resolved_target}" == "${home_real}/"* ]] || die "Đường dẫn dự án phải nằm bên trong home đã chọn."
  walk="${home_real}"
  for part in "${parts[@]}"; do walk="${walk}/${part}"; [[ ! -L "${walk}" ]] || die "Đường dẫn dự án không được đi qua symlink: ${walk}"; done
  if [[ -e "${STACK_DIR}" ]]; then
    [[ -f "${STACK_DIR}/.project-managed" ]] || die "Thư mục đích đã tồn tại và không có dấu quản lý của installer: ${STACK_DIR}"
    marker="$(cat "${STACK_DIR}/.project-managed")"
    [[ "${marker}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "Dấu quản lý dự án bị lỗi; không tự ghi đè."
    [[ -f "${STACK_DIR}/.env" ]] || die "Thiếu .env trong dự án đã quản lý; hãy khôi phục cấu hình trước khi chạy installer."
    saved_slug="$(read_config_value PROJECT_SLUG)"
    [[ "${saved_slug}" == "${marker}" ]] || die "Mã dự án trong .env không khớp dấu quản lý; hãy sửa qua manage.sh trước."
    PROJECT_SLUG="${PROJECT_SLUG:-${saved_slug}}"
    PROJECT_NAME="${PROJECT_NAME:-$(read_config_value PROJECT_NAME)}"
    saved_home="$(read_config_value PROJECT_HOME)"
    [[ -z "${saved_home}" || "$(realpath -e "${saved_home}" 2>/dev/null || true)" == "${home_real}" ]] || die "Thư mục đang lưu thuộc home khác; nhập đúng home dự án đã cài."
    EDGE_NETWORK="${EDGE_NETWORK:-$(read_config_value EDGE_NETWORK)}"
    APP_NETWORK="${APP_NETWORK:-$(read_config_value APP_NETWORK)}"
    EDGE_SUBNET="${EDGE_SUBNET:-$(read_config_value EDGE_SUBNET)}"
    APP_SUBNET="${APP_SUBNET:-$(read_config_value APP_SUBNET)}"
  else
    PROJECT_SLUG="${PROJECT_SLUG:-${default_slug}}"
    PROJECT_NAME="${PROJECT_NAME:-${PROJECT_SLUG}}"
  fi
  default_name="${PROJECT_NAME:-${PROJECT_SLUG}}"
  read -r -p "Tên hiển thị dự án [${default_name}]: " entered_name
  PROJECT_NAME="${entered_name:-${default_name}}"
  read -r -p "Mã dự án dùng cho Docker [${PROJECT_SLUG}]: " entered_slug
  PROJECT_SLUG="${entered_slug:-${PROJECT_SLUG}}"
  [[ -n "${PROJECT_NAME}" && "${PROJECT_NAME}" != *$'\n'* && "${PROJECT_NAME}" != *$'\r'* ]] || die "Tên hiển thị dự án không được để trống hoặc chứa xuống dòng."
  [[ "${PROJECT_SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "Mã dự án chỉ được gồm chữ thường, số, gạch ngang/gạch dưới; tối đa 48 ký tự."
  if [[ -e "${STACK_DIR}" ]]; then
    [[ "$(cat "${STACK_DIR}/.project-managed")" == "${PROJECT_SLUG}" ]] || die "Mã dự án khác cấu hình hiện có; hãy đổi trong manage.sh."
  fi
  DATA_DIR="${STACK_DIR}/data"
  TOKEN_FILE="${STACK_DIR}/secrets/cloudflare-tunnel-token"
  EDGE_NETWORK="${EDGE_NETWORK:-infra_edge}"
  APP_NETWORK="${APP_NETWORK:-infra_apps}"
  EDGE_SUBNET="${EDGE_SUBNET:-10.1.1.0/24}"
  APP_SUBNET="${APP_SUBNET:-10.1.2.0/24}"
}

validate_paths() {
  [[ "${STACK_DIR}" == /* && "${STACK_DIR}" != *[[:space:]:]* ]] || die "Đường dẫn dự án không hợp lệ."
  export STACK_DIR DATA_DIR PROJECT_HOME PROJECT_RELATIVE_DIR PROJECT_NAME PROJECT_SLUG
}

read_inputs() {
  if [[ ! -t 0 ]]; then
    die "Cần chạy tương tác để nhập domain và Cloudflare Tunnel token an toàn."
  fi
  set +x

  printf '\nCấu hình Cloudflare Tunnel đang được quản lý qua Cloudflare Dashboard.\n'
  local saved_domain
  saved_domain="$(read_config_value DOMAIN)"
  local default_domain="${saved_domain:-${DEFAULT_DOMAIN:-pn.id.vn}}"
  read -r -p "Domain gốc (ví dụ pn.id.vn) [${default_domain}]: " DOMAIN
  DOMAIN="${DOMAIN:-${default_domain}}"
  [[ "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Domain không hợp lệ. Chỉ nhập domain, không thêm https:// hoặc hostname con."

  mkdir -p "${STACK_DIR}/secrets"
  chmod 700 "${STACK_DIR}/secrets"

  if [[ -s "${TOKEN_FILE}" ]]; then
    read -r -p "Đã có Tunnel token. Giữ token đang lưu? [Y/n]: " answer
    if [[ "${answer}" =~ ^([nN]|no|NO)$ ]]; then
      read -r -s -p "Token mới (Enter để giữ token cũ): " TUNNEL_TOKEN
      printf '\n'
    fi
    TUNNEL_ENABLED="yes"
  else
    read -r -s -p "Cloudflare Tunnel token (Enter để cấu hình sau): " TUNNEL_TOKEN
    printf '\n'
    if [[ -n "${TUNNEL_TOKEN}" ]]; then
      TUNNEL_ENABLED="yes"
    else
      TUNNEL_ENABLED="no"
      printf 'Chưa cấu hình token; NPM và Portainer sẽ được cài, Tunnel để tắt.\n'
    fi
  fi
}

check_network_overlap() {
  [[ "${EDGE_SUBNET}" != "${APP_SUBNET}" ]] || die "EDGE_SUBNET và APP_SUBNET phải khác nhau."
}

installed_package() {
  local package="$1"
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null || true)" == installed ]]
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 || die "Docker đã có nhưng Docker Compose plugin chưa dùng được. Cài compose-plugin rồi chạy lại; script không tự thay thế Docker đang dùng."
    if ! command -v curl >/dev/null 2>&1; then
      log "Cài curl để kiểm tra phiên bản dự án trên GitHub khi start."
      if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl; then
        :
      else
        log "Không cài được curl; cài đặt stack vẫn tiếp tục, nhưng kiểm tra GitHub sẽ bị bỏ qua cho tới khi cài curl."
      fi
    fi
    systemctl enable --now docker
    log "Dùng Docker hiện có: $(docker --version)"
    return
  fi

  local conflicts=()
  local package
  for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if installed_package "${package}"; then conflicts+=("${package}"); fi
  done
  if ((${#conflicts[@]})); then
    printf 'Phát hiện gói có thể xung đột với Docker CE: %s\n' "${conflicts[*]}" >&2
    die "Hãy rà soát và gỡ các gói Docker/containerd cũ theo hướng dẫn Docker trước; script không tự gỡ vì thao tác đó có thể ảnh hưởng container đang chạy."
  fi

  log "Cài Docker Engine từ kho APT chính thức của Docker (${REPO_DISTRO}/${CODENAME})."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${REPO_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${REPO_DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version >/dev/null
}

ensure_network() {
  local name="$1" subnet="$2" current
  if docker network inspect "${name}" >/dev/null 2>&1; then
    current="$(docker network inspect --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "${name}" | tr -d '\n')"
    [[ "${current}" == "${subnet}" ]] || die "Docker network ${name} đã tồn tại với subnet ${current}; không tự sửa network đang dùng."
    log "Giữ Docker network ${name} (${current})."
  else
    docker network create --driver bridge --subnet="${subnet}" "${name}" >/dev/null \
      || die "Không tạo được Docker network ${name}/${subnet}; kiểm tra xung đột subnet với LAN, VPN hoặc Docker network khác."
    log "Đã tạo Docker network ${name} (${subnet})."
  fi
}

prepare_secret_group() {
  if ! getent group "${SECRET_GROUP}" >/dev/null; then
    groupadd --system "${SECRET_GROUP}"
  fi
  local group_entry
  group_entry="$(getent group "${SECRET_GROUP}")"
  [[ -z "$(printf '%s' "${group_entry}" | cut -d: -f4)" ]] || die "Group ${SECRET_GROUP} đã có thành viên; không thể dùng group này để bảo vệ Tunnel token."
  SECRET_GID="$(printf '%s' "${group_entry}" | cut -d: -f3)"
  [[ "${SECRET_GID}" =~ ^[0-9]+$ ]] || die "Không lấy được GID cho group ${SECRET_GROUP}."
}

save_secret() {
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    umask 0077
    printf '%s' "${TUNNEL_TOKEN}" > "${TOKEN_FILE}"
    unset TUNNEL_TOKEN
  fi
  if [[ -s "${TOKEN_FILE}" ]]; then
    chown root:"${SECRET_GROUP}" "${TOKEN_FILE}"
    chmod 0440 "${TOKEN_FILE}"
    TUNNEL_ENABLED="yes"
  else
    : > "${TOKEN_FILE}"
    chown root:root "${TOKEN_FILE}"
    chmod 0440 "${TOKEN_FILE}"
    TUNNEL_ENABLED="no"
  fi
}

read_config_value() {
  local key="$1" file="${STACK_DIR}/.env"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${file}"
}

write_config_value() {
  local key="$1" value="$2" file="${STACK_DIR}/.env" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { prefix = key "=" }
    index($0, prefix) == 1 { print prefix value; found = 1; next }
    { print }
    END { if (!found) print prefix value }
  ' "${file}" > "${tmp}"
  chown root:root "${tmp}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${file}"
}

compose() {
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" -p "${PROJECT_SLUG}" "$@"
}

load_project_config() {
  PROJECT_HOME="$(read_config_value PROJECT_HOME)"
  PROJECT_RELATIVE_DIR="$(read_config_value PROJECT_RELATIVE_DIR)"
  PROJECT_NAME="$(read_config_value PROJECT_NAME)"
  PROJECT_SLUG="$(read_config_value PROJECT_SLUG)"
  DATA_DIR="$(read_config_value DATA_DIR)"
  TOKEN_FILE="${STACK_DIR}/secrets/cloudflare-tunnel-token"
  EDGE_NETWORK="$(read_config_value EDGE_NETWORK)"
  APP_NETWORK="$(read_config_value APP_NETWORK)"
  TUNNEL_ENABLED="$(read_config_value TUNNEL_ENABLED)"
  if [[ -z "${TUNNEL_ENABLED}" ]]; then
    if [[ -s "${TOKEN_FILE}" ]]; then TUNNEL_ENABLED=yes; else TUNNEL_ENABLED=no; fi
  fi
}

update_domain() {
  local domain
  read -r -p "Domain gốc mới: " domain
  [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Domain không hợp lệ. Chỉ nhập domain, không thêm https:// hoặc hostname con."
  write_config_value DOMAIN "${domain}"
  printf '\nĐã lưu domain %s. Cần cập nhật Public Hostname thủ công trong Cloudflare Zero Trust:\n' "${domain}"
  printf '  proxy.%s -> HTTP -> npm:81\n' "${domain}"
  printf '  %s -> HTTP -> npm:80\n' "${domain}"
  printf '  docker.%s -> HTTP -> npm:80 (sau đó cập nhật Proxy Host trong NPM)\n' "${domain}"
}

replace_tunnel_token() {
  local token tmp
  read -r -s -p "Nhập Cloudflare Tunnel token mới (ký tự sẽ không hiển thị): " token
  printf '\n'
  [[ -n "${token}" ]] || die "Tunnel token không được để trống."
  getent group "${SECRET_GROUP}" >/dev/null || die "Không tìm thấy group ${SECRET_GROUP}; hãy chạy lại installer để sửa cấu hình."
  umask 0077
  tmp="$(mktemp "${TOKEN_FILE}.tmp.XXXXXX")"
  printf '%s' "${token}" > "${tmp}"
  unset token
  chown root:"${SECRET_GROUP}" "${tmp}"
  chmod 0440 "${tmp}"
  mv -f "${tmp}" "${TOKEN_FILE}"
  write_config_value TUNNEL_ENABLED yes
  TUNNEL_ENABLED=yes

  log "Đã thay token. Khởi động lại riêng cloudflared để nạp secret mới."
  compose --profile tunnel up -d --force-recreate cloudflared
}

apply_saved_stack() {
  if [[ "${TUNNEL_ENABLED}" == yes && -s "${TOKEN_FILE}" ]]; then
    compose --profile all config --quiet
    compose --profile all up -d
  else
    compose --profile npm --profile portainer config --quiet
    compose --profile npm --profile portainer up -d
  fi
}

write_project_helpers() {
  cat > "${STACK_DIR}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ ${EUID} -eq 0 ]] || { echo "Chạy bằng sudo: sudo $0" >&2; exit 1; }

env_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${DIR}/.env"; }
SLUG="$(env_value PROJECT_SLUG)"
REPO="$(env_value UPDATE_REPO)"
BRANCH="$(env_value UPDATE_BRANCH)"
LOCAL_COMMIT="$(env_value INSTALLED_COMMIT)"
TUNNEL_ENABLED="$(env_value TUNNEL_ENABLED)"
[[ "${SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || { echo "PROJECT_SLUG không hợp lệ" >&2; exit 1; }
REPO="${REPO:-https://github.com/tungtk0021/ubuntu-deploy}"
BRANCH="${BRANCH:-main}"
API_REPO="${REPO#https://github.com/}"
API_REPO="${API_REPO%.git}"
API_REF="${BRANCH//\//%2F}"
STATE_FILE="${DIR}/.update-state"

if [[ -t 0 ]] && command -v curl >/dev/null 2>&1; then
  printf 'Đang kiểm tra bản cập nhật trên GitHub... '
  API_JSON="$(curl -fsSL --connect-timeout 3 --max-time 8 "https://api.github.com/repos/${API_REPO}/commits/${API_REF}" 2>/dev/null || true)"
  LATEST_COMMIT="$(printf '%s\n' "${API_JSON}" | sed -n 's/^[[:space:]]*"sha": "\([0-9a-f]\{40\}\)",$/\1/p' | head -n1)"
  if [[ "${LATEST_COMMIT}" =~ ^[0-9a-f]{40}$ && "${LATEST_COMMIT}" != "${LOCAL_COMMIT}" ]]; then
    SKIP_UNTIL="$(awk -F= '$1 == "SKIP_UNTIL" {print $2; exit}' "${STATE_FILE}" 2>/dev/null || true)"
    SKIP_COMMIT="$(awk -F= '$1 == "SKIP_COMMIT" {print $2; exit}' "${STATE_FILE}" 2>/dev/null || true)"
    NOW="$(date +%s)"
    if [[ "${SKIP_COMMIT}" != "${LATEST_COMMIT}" && ( ! "${SKIP_UNTIL}" =~ ^[0-9]+$ || ${SKIP_UNTIL} -le ${NOW} ) ]]; then
      printf '\nCó commit mới: %s (đang cài: %s)\n' "${LATEST_COMMIT:0:12}" "${LOCAL_COMMIT:0:12}"
      printf 'u) Cập nhật ngay   t) Nhắc lại sau 7 ngày   p) Bỏ qua commit này\n'
      printf 's) Bỏ qua lần này   q) Thoát, không start\n'
      read -r -p 'Chọn: ' UPDATE_CHOICE
      case "${UPDATE_CHOICE}" in
        u|U)
          if ! command -v tar >/dev/null 2>&1; then
            echo 'Thiếu lệnh tar; cài bằng sudo apt-get install tar. Giữ nguyên phiên bản hiện tại.' >&2
          else
            TMP_DIR="$(mktemp -d)"
            trap 'rm -rf -- "${TMP_DIR}"' EXIT
            if ! curl -fsSL --connect-timeout 5 --max-time 120 "https://api.github.com/repos/${API_REPO}/tarball/${LATEST_COMMIT}" -o "${TMP_DIR}/source.tar.gz"; then
              echo 'Không tải được mã nguồn cập nhật; giữ nguyên phiên bản hiện tại.' >&2
            elif mkdir "${TMP_DIR}/source" && tar -xzf "${TMP_DIR}/source.tar.gz" --strip-components=1 -C "${TMP_DIR}/source"; then
            if "${TMP_DIR}/source/update-project.sh" "${DIR}" "${LATEST_COMMIT}" "${BRANCH}"; then
                exit 0
              else
                echo 'Cập nhật thất bại; thử khởi động phiên bản hiện tại.' >&2
              fi
            else
              echo 'Không thể giải nén mã nguồn cập nhật; giữ nguyên phiên bản hiện tại.' >&2
            fi
          fi
          ;;
        t|T)
          printf 'SKIP_UNTIL=%s\n' "$((NOW + 604800))" > "${STATE_FILE}"
          chmod 0600 "${STATE_FILE}"
          ;;
        p|P)
          printf 'SKIP_COMMIT=%s\n' "${LATEST_COMMIT}" > "${STATE_FILE}"
          chmod 0600 "${STATE_FILE}"
          ;;
        s|S) ;;
        q|Q) exit 0 ;;
        *) echo 'Lựa chọn không hợp lệ; tiếp tục start phiên bản hiện tại.' ;;
      esac
    else
      printf 'đã có phiên bản mới nhưng đang trong thời gian bỏ qua.\n'
    fi
  elif [[ "${LATEST_COMMIT}" == "${LOCAL_COMMIT}" && -n "${LATEST_COMMIT}" ]]; then
    printf 'đang dùng commit mới nhất (%s).\n' "${LATEST_COMMIT:0:12}"
  else
    printf 'không truy vấn được GitHub; tiếp tục dùng phiên bản hiện tại.\n'
  fi
elif [[ -t 0 ]]; then
  printf 'Không tìm thấy curl; bỏ qua kiểm tra GitHub và dùng phiên bản hiện tại.\n'
fi

if [[ "${TUNNEL_ENABLED}" == yes && -s "${DIR}/secrets/cloudflare-tunnel-token" ]]; then
  docker compose --project-directory "${DIR}" -f "${DIR}/compose.yaml" -p "${SLUG}" --profile all up -d
else
  docker compose --project-directory "${DIR}" -f "${DIR}/compose.yaml" -p "${SLUG}" --profile npm --profile portainer up -d
fi
EOF
  cat > "${STACK_DIR}/stop.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ ${EUID} -eq 0 ]] || { echo "Chạy bằng sudo: sudo $0" >&2; exit 1; }
SLUG="$(sed -n 's/^PROJECT_SLUG=//p' "${DIR}/.env" | head -n1)"
[[ "${SLUG}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || { echo "PROJECT_SLUG không hợp lệ" >&2; exit 1; }
docker compose --project-directory "${DIR}" -f "${DIR}/compose.yaml" -p "${SLUG}" --profile all stop
EOF
  chmod 0750 "${STACK_DIR}/start.sh" "${STACK_DIR}/stop.sh"
  cp "${SCRIPT_DIR}/manage-config.sh" "${STACK_DIR}/manage.sh"
  chmod 0750 "${STACK_DIR}/manage.sh"
  install -d -m 0750 "${STACK_DIR}/lib"
  cp "${SCRIPT_DIR}/lib/deploy-common.sh" "${STACK_DIR}/lib/deploy-common.sh"
  chmod 0640 "${STACK_DIR}/lib/deploy-common.sh"
}

project_dir_for_relative() {
  local base="$1" relative="$2" part
  [[ "${relative}" != /* && "${relative}" != *:* && "${relative}" != *[[:space:]]* ]] || return 1
  IFS=/ read -ra pieces <<< "${relative}"
  for part in "${pieces[@]}"; do [[ -n "${part}" && "${part}" != . && "${part}" != .. ]] || return 1; done
  printf '%s/%s' "${base}" "${relative}"
}

rename_project() {
  local new_name new_slug new_rel target old_dir old_slug home_real walk part
  read -r -p "Tên hiển thị mới [${PROJECT_NAME}]: " new_name
  new_name="${new_name:-${PROJECT_NAME}}"
  read -r -p "Mã dự án Docker mới [${PROJECT_SLUG}]: " new_slug
  new_slug="${new_slug:-${PROJECT_SLUG}}"
  [[ "${new_slug}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "Mã dự án không hợp lệ."
  [[ -n "${new_name}" && "${new_name}" != *$'\n'* && "${new_name}" != *$'\r'* ]] || die "Tên hiển thị không hợp lệ."
  read -r -p "Đường dẫn mới bên trong ${PROJECT_HOME} [${PROJECT_RELATIVE_DIR}]: " new_rel
  new_rel="${new_rel:-${PROJECT_RELATIVE_DIR}}"
  target="$(project_dir_for_relative "${PROJECT_HOME}" "${new_rel}")" || die "Đường dẫn tương đối không hợp lệ."
  old_dir="$(realpath -e "${STACK_DIR}")"
  home_real="$(realpath -e "${PROJECT_HOME}")"
  walk="${home_real}"
  IFS=/ read -ra target_parts <<< "${new_rel}"
  for part in "${target_parts[@]}"; do walk="${walk}/${part}"; [[ ! -L "${walk}" ]] || die "Đường dẫn đích không được đi qua symlink: ${walk}"; done
  target="$(realpath -m -- "${target}")"
  [[ "${old_dir}" == "${home_real}/"* && "${target}" == "${home_real}/"* && ! -L "${target}" ]] || die "Dự án phải nằm dưới home đã cấu hình và không đi qua symlink."
  [[ "${target}" != "${old_dir}/"* ]] || die "Không thể chuyển dự án vào bên trong chính thư mục dự án."
  [[ ! -e "${target}" || "${target}" == "${old_dir}" ]] || die "Đích đã tồn tại: ${target}"
  printf '\nSẽ đổi dự án thành %s (%s), chuyển từ %s đến %s.\n' "${new_name}" "${new_slug}" "${old_dir}" "${target}"
  read -r -p "Gõ MOVE ${PROJECT_SLUG} để xác nhận: " confirmation
  [[ "${confirmation}" == "MOVE ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; return; }
  old_slug="${PROJECT_SLUG}"
  compose --profile all down
  install -d -m 0750 "$(dirname "${target}")"
  mv -- "${old_dir}" "${target}"
  STACK_DIR="${target}"
  DATA_DIR="${STACK_DIR}/data"
  PROJECT_RELATIVE_DIR="${new_rel}"
  PROJECT_NAME="${new_name}"
  PROJECT_SLUG="${new_slug}"
  TOKEN_FILE="${STACK_DIR}/secrets/cloudflare-tunnel-token"
  write_config_value PROJECT_NAME "${PROJECT_NAME}"
  write_config_value PROJECT_SLUG "${PROJECT_SLUG}"
  write_config_value PROJECT_RELATIVE_DIR "${PROJECT_RELATIVE_DIR}"
  write_config_value DATA_DIR "${DATA_DIR}"
  printf '%s' "${PROJECT_SLUG}" > "${STACK_DIR}/.project-managed"
  log "Đã chuyển dự án. Stack cũ (${old_slug}) đã được dừng; dùng ${STACK_DIR}/start.sh để khởi động."
  exit 0
}

restore_project_data() {
  local source_dir backup_stamp backup_dir layout
  read -r -p "Đường dẫn thư mục dữ liệu dự án cũ: " source_dir
  [[ -d "${source_dir}" && ! -L "${source_dir}" ]] || die "Không tìm thấy thư mục nguồn hợp lệ."
  source_dir="$(realpath -e "${source_dir}")"
  [[ "${source_dir}" != "${STACK_DIR}" && "${source_dir}" != "${DATA_DIR}" && "${source_dir}" != "${STACK_DIR}/"* ]] || die "Nguồn không được nằm trong dự án đang chạy."
  if [[ -d "${source_dir}/data/npm/data" ]]; then layout="${source_dir}/data"
  elif [[ -d "${source_dir}/npm/data" ]]; then layout="${source_dir}"
  elif [[ -d "${source_dir}/npm" && -d "${source_dir}/portainer" ]]; then layout="${source_dir}"
  else die "Không nhận diện được dữ liệu cũ. Cần npm/data, npm/letsencrypt và portainer (hoặc data/npm/data...)."; fi
  local portainer_source="${layout}/portainer"
  [[ -d "${layout}/npm/data" && -d "${layout}/npm/letsencrypt" ]] || die "Thiếu thư mục NPM data hoặc letsencrypt."
  [[ -d "${portainer_source}/data" ]] && portainer_source="${portainer_source}/data"
  [[ -d "${portainer_source}" ]] || die "Thiếu thư mục dữ liệu Portainer."
  printf '\nKhôi phục dữ liệu từ: %s\nDữ liệu hiện tại sẽ được giữ trong backups trước khi thay thế.\n' "${layout}"
  read -r -p "Gõ RESTORE ${PROJECT_SLUG} để xác nhận: " confirmation
  [[ "${confirmation}" == "RESTORE ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; return; }
  compose --profile all down
  backup_stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="$(mktemp -d "${STACK_DIR}/backups/pre-restore-${backup_stamp}-XXXXXX")"
  chmod 0750 "${backup_dir}"
  if [[ -d "${DATA_DIR}" ]]; then mv -- "${DATA_DIR}" "${backup_dir}/data"; fi
  install -d -m 0750 "${DATA_DIR}/npm/data" "${DATA_DIR}/npm/letsencrypt" "${DATA_DIR}/portainer"
  cp -a "${layout}/npm/data/." "${DATA_DIR}/npm/data/"
  cp -a "${layout}/npm/letsencrypt/." "${DATA_DIR}/npm/letsencrypt/"
  cp -a "${portainer_source}/." "${DATA_DIR}/portainer/"
  log "Khôi phục xong. Dịch vụ vẫn đang dừng; kiểm tra cấu hình rồi chạy ${STACK_DIR}/start.sh. Token Cloudflare không được nhập từ nguồn cũ."
}

wipe_project() {
  local real_dir home_real confirmation
  real_dir="$(realpath -e "${STACK_DIR}")"
  home_real="$(realpath -e "${PROJECT_HOME}")"
  [[ "${real_dir}" == "${home_real}/"* && -f "${real_dir}/.project-managed" && "$(cat "${real_dir}/.project-managed")" == "${PROJECT_SLUG}" ]] || die "Kiểm tra an toàn thất bại; không xóa thư mục không được installer quản lý."
  [[ "${real_dir}" != "${home_real}" && "${real_dir}" != / && ! -L "${STACK_DIR}" ]] || die "Từ chối xóa home, root hoặc symlink."
  printf '\nSẼ XÓA VĨNH VIỄN toàn bộ dự án và dữ liệu, secrets, backups tại:\n  %s\n' "${real_dir}"
  read -r -p "Gõ WIPE ${PROJECT_SLUG} để xác nhận: " confirmation
  [[ "${confirmation}" == "WIPE ${PROJECT_SLUG}" ]] || { printf 'Đã hủy.\n'; return; }
  compose --profile all down
  cd "${PROJECT_HOME}"
  rm -rf --one-file-system -- "${real_dir}"
  log "Đã xóa dự án ${PROJECT_SLUG}."
  exit 0
}

manage_main() {
  require_root
  load_project_config
  [[ -f "${STACK_DIR}/compose.yaml" && -f "${STACK_DIR}/.env" ]] || die "Chưa tìm thấy cấu hình stack tại ${STACK_DIR}; hãy chạy installer trước."
  [[ -t 0 ]] || die "Trình quản lý cần chạy trong terminal tương tác."
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    || die "Không tìm thấy Docker Compose plugin hoạt động."
  set +x

  local choice domain data_dir edge_network app_network
  while true; do
    domain="$(read_config_value DOMAIN)"
    data_dir="$(read_config_value DATA_DIR)"
    edge_network="$(read_config_value EDGE_NETWORK)"
    app_network="$(read_config_value APP_NETWORK)"
    printf '\n=== QUẢN LÝ DỰ ÁN: %s (%s) ===\n' "${PROJECT_NAME}" "${PROJECT_SLUG}"
    printf 'Thư mục: %s | Domain: %s | Networks: %s, %s | Tunnel: %s\n' "${STACK_DIR}" "${domain:-chưa đặt}" "${edge_network:-infra_edge}" "${app_network:-infra_apps}" "${TUNNEL_ENABLED:-no}"
    printf '1) Sửa domain gốc\n2) Thay Cloudflare Tunnel token\n3) Áp dụng Compose (bật Tunnel nếu đã có token)\n4) Đổi tên/mã/vị trí dự án\n5) Khôi phục dữ liệu từ dự án cũ\n6) Xóa trắng toàn bộ dự án\n0) Thoát\n'
    read -r -p 'Chọn tác vụ: ' choice
    case "${choice}" in
      1) update_domain ;;
      2) replace_tunnel_token ;;
      3) apply_saved_stack ;;
      4) rename_project ;;
      5) restore_project_data ;;
      6) wipe_project ;;
      0) return 0 ;;
      *) printf 'Lựa chọn không hợp lệ.\n' >&2 ;;
    esac
  done
}

write_compose_config() {
  install -d -o root -g root -m 0750 "${STACK_DIR}" "${STACK_DIR}/secrets"
  install -d -m 0750 "${STACK_DIR}/backups"
  install -d -m 0750 "${DATA_DIR}/npm/data" "${DATA_DIR}/npm/letsencrypt" "${DATA_DIR}/portainer"

  cat > "${STACK_DIR}/.env" <<EOF
PROJECT_NAME=${PROJECT_NAME}
PROJECT_SLUG=${PROJECT_SLUG}
PROJECT_HOME=${PROJECT_HOME}
PROJECT_RELATIVE_DIR=${PROJECT_RELATIVE_DIR}
DOMAIN=${DOMAIN}
DATA_DIR=${DATA_DIR}
TUNNEL_ENABLED=${TUNNEL_ENABLED}
UPDATE_REPO=${UPDATE_REPO}
UPDATE_BRANCH=${UPDATE_BRANCH}
INSTALLED_COMMIT=${INSTALLED_COMMIT}
EDGE_NETWORK=${EDGE_NETWORK}
APP_NETWORK=${APP_NETWORK}
EDGE_SUBNET=${EDGE_SUBNET}
APP_SUBNET=${APP_SUBNET}
CLOUDFLARED_SECRET_GID=${SECRET_GID}
EOF
  chmod 0600 "${STACK_DIR}/.env"

  install -m 0640 "${SCRIPT_DIR}/compose.yaml" "${STACK_DIR}/compose.yaml"
  chown root:root "${STACK_DIR}/.env" "${STACK_DIR}/compose.yaml"
  printf '%s' "${PROJECT_SLUG}" > "${STACK_DIR}/.project-managed"
  chmod 0640 "${STACK_DIR}/.project-managed"
  write_project_helpers
}

deploy_stack() {
  log "Kiểm tra Compose configuration."
  if [[ "${TUNNEL_ENABLED}" == yes && -s "${TOKEN_FILE}" ]]; then
    compose --profile all config --quiet
    log "Tải image và khởi chạy dịch vụ."
    compose --profile all pull
    compose --profile all up -d
  else
    compose --profile npm --profile portainer config --quiet
    log "Tải image và khởi chạy NPM, Portainer (Tunnel chưa cấu hình)."
    compose --profile npm --profile portainer pull
    compose --profile npm --profile portainer up -d
  fi
}

print_summary() {
  cat <<EOF

Cài đặt dự án ${PROJECT_NAME} (${PROJECT_SLUG}) hoàn tất trên ${PRETTY_NAME:-${ID}}.

Thư mục dự án : ${STACK_DIR}
Thư mục dữ liệu: ${DATA_DIR}
Docker network : ${EDGE_NETWORK} (${EDGE_SUBNET}), ${APP_NETWORK} (${APP_SUBNET})

Trong Cloudflare Zero Trust, thêm Public Hostname:
  proxy.${DOMAIN}  -> HTTP  -> npm:81
  ${DOMAIN}        -> HTTP  -> npm:80

Không có cổng dịch vụ nào được publish trực tiếp lên host.
Portainer và NPM yêu cầu tạo tài khoản quản trị ở lần đăng nhập đầu tiên.
Không có tài khoản/mật khẩu mặc định được tạo bởi script.

Trong thư mục dự án có start.sh, stop.sh, manage.sh, compose.yaml, secrets/, data/ và backups/.
Chạy dự án: sudo ${STACK_DIR}/start.sh | Dừng toàn bộ: sudo ${STACK_DIR}/stop.sh
Quản lý/đổi tên/khôi phục/xóa: sudo ${STACK_DIR}/manage.sh
EOF
  if [[ "${TUNNEL_ENABLED}" != yes ]]; then
    cat <<'EOF'

Cloudflare Tunnel hiện chưa bật vì chưa có token. Khi có token, chạy manage.sh và chọn “Thay Cloudflare Tunnel token”; các lần start sau sẽ tự chạy Tunnel.
EOF
  fi
}

deploy_main() {
  local expected="$1"
  if [[ "${2:-}" == "--help" ]]; then usage; return 0; fi
  [[ $# -eq 1 ]] || die "Tham số không hợp lệ. Dùng --help để xem cách sử dụng."

  require_root
  check_os "${expected}"
  if command -v git >/dev/null 2>&1 && git -c safe.directory="${SCRIPT_DIR}" -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local source_branch source_commit source_remote
    source_branch="$(git -c safe.directory="${SCRIPT_DIR}" -C "${SCRIPT_DIR}" branch --show-current)"
    source_commit="$(git -c safe.directory="${SCRIPT_DIR}" -C "${SCRIPT_DIR}" rev-parse HEAD)"
    source_remote="$(git -c safe.directory="${SCRIPT_DIR}" -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
    [[ -z "${source_branch}" ]] || UPDATE_BRANCH="${source_branch}"
    [[ -z "${source_commit}" ]] || INSTALLED_COMMIT="${source_commit}"
    case "${source_remote}" in
      https://github.com/*) UPDATE_REPO="${source_remote%.git}" ;;
      git@github.com:*) UPDATE_REPO="https://github.com/${source_remote#git@github.com:}"; UPDATE_REPO="${UPDATE_REPO%.git}" ;;
    esac
  fi
  choose_project_location
  validate_paths
  check_network_overlap
  read_inputs

  install_docker
  ensure_network "${EDGE_NETWORK}" "${EDGE_SUBNET}"
  ensure_network "${APP_NETWORK}" "${APP_SUBNET}"
  prepare_secret_group
  save_secret
  write_compose_config
  deploy_stack
  print_summary
}
