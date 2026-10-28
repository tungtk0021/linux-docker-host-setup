#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly STACK_DIR="${STACK_DIR:-/opt/infra-stack}"
readonly TOKEN_FILE="${STACK_DIR}/secrets/cloudflare-tunnel-token"
readonly EDGE_NETWORK="${EDGE_NETWORK:-infra_edge}"
readonly APP_NETWORK="${APP_NETWORK:-infra_apps}"
readonly EDGE_SUBNET="${EDGE_SUBNET:-10.1.1.0/24}"
readonly APP_SUBNET="${APP_SUBNET:-10.1.2.0/24}"
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
  STACK_DIR       Thư mục cấu hình (mặc định /opt/infra-stack)
  DATA_DIR        Thư mục dữ liệu bền vững (mặc định /srv/infra-data)
  EDGE_SUBNET     Docker network cho Tunnel/NPM/Portainer (10.1.1.0/24)
  APP_SUBNET      Docker network cho ứng dụng (10.1.2.0/24)

Không truyền Cloudflare Tunnel token qua command line hoặc biến môi trường.
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Hãy chạy script bằng sudo hoặc tài khoản root."
  command -v apt-get >/dev/null 2>&1 || die "Chỉ hỗ trợ hệ Debian/Ubuntu dùng APT."
  command -v systemctl >/dev/null 2>&1 || die "Không tìm thấy systemd; script yêu cầu máy chủ dùng systemd."
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

validate_paths() {
  [[ "${STACK_DIR}" == /* && "${STACK_DIR}" != *[[:space:]:]* ]] || die "STACK_DIR phải là đường dẫn tuyệt đối, không chứa khoảng trắng hoặc dấu hai chấm."

  local default_data_dir="${DATA_DIR:-}"
  if [[ -z "${default_data_dir}" && -f "${STACK_DIR}/.env" ]]; then
    default_data_dir="$(sed -n 's/^DATA_DIR=//p' "${STACK_DIR}/.env" | head -n 1)"
  fi
  default_data_dir="${default_data_dir:-/srv/infra-data}"

  if [[ -t 0 ]]; then
    read -r -p "Thư mục lưu dữ liệu NPM/Portainer [${default_data_dir}]: " entered_data_dir
    DATA_DIR="${entered_data_dir:-${default_data_dir}}"
  else
    DATA_DIR="${default_data_dir}"
  fi

  [[ "${DATA_DIR}" == /* && "${DATA_DIR}" != *[[:space:]:]* ]] || die "DATA_DIR phải là đường dẫn tuyệt đối, không chứa khoảng trắng hoặc dấu hai chấm."
  export DATA_DIR
}

read_inputs() {
  if [[ ! -t 0 ]]; then
    die "Cần chạy tương tác để nhập domain và Cloudflare Tunnel token an toàn."
  fi
  set +x

  printf '\nCấu hình Cloudflare Tunnel đang được quản lý qua Cloudflare Dashboard.\n'
  read -r -p "Nhập domain gốc (ví dụ: pn.id.vn): " DOMAIN
  [[ "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Domain không hợp lệ. Chỉ nhập domain, không thêm https:// hoặc hostname con."

  mkdir -p "${STACK_DIR}/secrets"
  chmod 700 "${STACK_DIR}/secrets"

  local replace_token="yes"
  if [[ -s "${TOKEN_FILE}" ]]; then
    read -r -p "Đã có Tunnel token. Giữ token đang lưu? [Y/n]: " answer
    if [[ ! "${answer}" =~ ^([nN]|no|NO)$ ]]; then
      replace_token="no"
    fi
  fi

  if [[ "${replace_token}" == "yes" ]]; then
    read -r -s -p "Nhập Cloudflare Tunnel token (ký tự sẽ không hiển thị): " TUNNEL_TOKEN
    printf '\n'
    [[ -n "${TUNNEL_TOKEN}" ]] || die "Tunnel token không được để trống."
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
  [[ -s "${TOKEN_FILE}" ]] || die "Không có Cloudflare Tunnel token."
  chown root:"${SECRET_GROUP}" "${TOKEN_FILE}"
  chmod 0440 "${TOKEN_FILE}"
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

  log "Đã thay token. Khởi động lại riêng cloudflared để nạp secret mới."
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
    --profile tunnel up -d --force-recreate cloudflared
}

apply_saved_stack() {
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
    --profile all config --quiet
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" \
    --profile all up -d
}

manage_main() {
  require_root
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
    printf '\n=== QUẢN LÝ CẤU HÌNH DEPLOY ===\n'
    printf 'Domain: %s | Data: %s | Networks: %s, %s\n' "${domain:-chưa đặt}" "${data_dir:-chưa đặt}" "${edge_network:-infra_edge}" "${app_network:-infra_apps}"
    printf '1) Sửa domain gốc\n2) Thay Cloudflare Tunnel token\n3) Áp dụng lại Compose và khởi động toàn bộ\n0) Thoát\n'
    read -r -p 'Chọn tác vụ: ' choice
    case "${choice}" in
      1) update_domain ;;
      2) replace_tunnel_token ;;
      3) apply_saved_stack ;;
      0) return 0 ;;
      *) printf 'Lựa chọn không hợp lệ.\n' >&2 ;;
    esac
  done
}

write_compose_config() {
  install -d -o root -g root -m 0750 "${STACK_DIR}" "${STACK_DIR}/secrets"
  install -d -m 0750 "${DATA_DIR}/npm/data" "${DATA_DIR}/npm/letsencrypt" "${DATA_DIR}/portainer"

  cat > "${STACK_DIR}/.env" <<EOF
DOMAIN=${DOMAIN}
DATA_DIR=${DATA_DIR}
EDGE_NETWORK=${EDGE_NETWORK}
APP_NETWORK=${APP_NETWORK}
EDGE_SUBNET=${EDGE_SUBNET}
APP_SUBNET=${APP_SUBNET}
CLOUDFLARED_SECRET_GID=${SECRET_GID}
EOF
  chmod 0600 "${STACK_DIR}/.env"

  install -m 0640 "${SCRIPT_DIR}/compose.yaml" "${STACK_DIR}/compose.yaml"
  chown root:root "${STACK_DIR}/.env" "${STACK_DIR}/compose.yaml"
}

deploy_stack() {
  log "Kiểm tra Compose configuration."
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" config --quiet

  log "Tải image và khởi chạy dịch vụ."
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" pull
  docker compose --project-directory "${STACK_DIR}" -f "${STACK_DIR}/compose.yaml" up -d
}

print_summary() {
  cat <<EOF

Cài đặt hoàn tất trên ${PRETTY_NAME:-${ID}}.

Thư mục stack : ${STACK_DIR}
Thư mục dữ liệu: ${DATA_DIR}
Docker network : ${EDGE_NETWORK} (${EDGE_SUBNET}), ${APP_NETWORK} (${APP_SUBNET})

Trong Cloudflare Zero Trust, thêm Public Hostname:
  proxy.${DOMAIN}  -> HTTP  -> npm:81
  ${DOMAIN}        -> HTTP  -> npm:80

Không có cổng dịch vụ nào được publish trực tiếp lên host.
Portainer và NPM yêu cầu tạo tài khoản quản trị ở lần đăng nhập đầu tiên.
Không có tài khoản/mật khẩu mặc định được tạo bởi script.

Stack được lưu ở ${STACK_DIR}/compose.yaml. Khi cần cập nhật image, chỉnh tag đã ghim
trong file compose rồi chạy: docker compose -f ${STACK_DIR}/compose.yaml pull
và: docker compose -f ${STACK_DIR}/compose.yaml up -d
EOF
}

deploy_main() {
  local expected="$1"
  if [[ "${2:-}" == "--help" ]]; then usage; return 0; fi
  [[ $# -eq 1 ]] || die "Tham số không hợp lệ. Dùng --help để xem cách sử dụng."

  require_root
  check_os "${expected}"
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
