#!/usr/bin/env bash

RUNNING_CONTAINER_IDS=()

list_running_containers() {
  mapfile -t RUNNING_CONTAINER_IDS < <(docker ps -q)
  printf '\nCác Docker container đang chạy trên máy:\n'
  if ((${#RUNNING_CONTAINER_IDS[@]} == 0)); then
    printf '  Không có container nào đang chạy.\n'
  else
    docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}'
  fi
}

remove_all_running_containers() {
  local confirmation
  list_running_containers
  if ((${#RUNNING_CONTAINER_IDS[@]} == 0)); then
    return 0
  fi

  printf '\nThao tác này sẽ dừng và xóa TẤT CẢ container đang chạy trên máy, kể cả container ngoài dự án này.\n'
  printf 'Docker volumes, image và thư mục bind mount sẽ được giữ lại.\n'
  read -r -p 'Gõ REMOVE ALL CONTAINERS để xác nhận: ' confirmation
  [[ "${confirmation}" == 'REMOVE ALL CONTAINERS' ]] || { printf 'Đã hủy.\n'; return 0; }

  docker rm -f "${RUNNING_CONTAINER_IDS[@]}"
  printf 'Đã dừng và xóa toàn bộ container đã liệt kê; volumes và dữ liệu vẫn được giữ.\n'
}
