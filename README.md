# Ubuntu / Debian Docker host setup

Script cài Docker Engine, Docker Compose plugin, Nginx Proxy Manager (NPM), Portainer CE và Cloudflare Tunnel trên máy chủ Ubuntu hoặc Debian.

## Hệ điều hành hỗ trợ

- Ubuntu Server 22.04, 24.04 và 26.04 LTS.
- Debian 12 (Bookworm) và Debian 13 (Trixie).
- `amd64` và `arm64` cho các image dịch vụ được cấu hình trong Compose.

Docker được cài từ kho APT chính thức của Docker. Nếu máy đã có Docker và Compose, script giữ nguyên cài đặt đó. Nếu phát hiện gói Docker/containerd có thể xung đột, script dừng để quản trị viên rà soát; script không tự gỡ các gói đang có.

## Chạy cài đặt

Clone repo rồi chạy đúng script theo hệ điều hành:

```bash
git clone https://github.com/tungtk0021/ubuntu-deploy.git
cd ubuntu-deploy
chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh

sudo ./deploy-ubuntu.sh
# hoặc
sudo ./deploy-debian.sh
```

Script hỏi domain gốc và Cloudflare Tunnel token. Token được nhập ẩn, lưu riêng trong `/opt/infra-stack/secrets/cloudflare-tunnel-token` với quyền hạn chế, rồi mount dưới dạng Compose secret. Token không nằm trong file Compose, `.env`, lịch sử lệnh hay log script. Khi chạy lại, có thể giữ token đã lưu hoặc thay bằng token mới.

Mặc định dữ liệu NPM và Portainer nằm ở `/srv/infra-data`. Nếu dùng ổ đĩa riêng, hãy mount ổ đó trước khi cài và nhập đường dẫn mount làm thư mục dữ liệu. Script không tự sửa `/etc/fstab` hoặc mount NAS.

Có thể thay đổi thư mục và dải mạng trước khi chạy:

```bash
sudo env DATA_DIR=/mnt/infra-data \
  EDGE_SUBNET=10.1.1.0/24 APP_SUBNET=10.1.2.0/24 \
  ./deploy-ubuntu.sh
```

`EDGE_SUBNET` và `APP_SUBNET` phải không trùng nhau, không trùng mạng LAN/VPN và không xung đột Docker network đã có. Script mặc định tạo `infra_edge` (`10.1.1.0/24`) và `infra_apps` (`10.1.2.0/24`). Ứng dụng sau này có thể tham gia `infra_apps`; NPM tham gia cả hai mạng để proxy vào ứng dụng.

## Cloudflare Tunnel và hostname

Script chỉ tạo connector `cloudflared`; Tunnel và Public Hostname được quản lý trong Cloudflare Dashboard. Trong Zero Trust → Networks → Tunnels → chọn Tunnel → Public Hostnames, tạo:

| Hostname | Service |
| --- | --- |
| `proxy.example.com` | `HTTP` → `npm:81` (quản trị NPM) |
| `example.com` | `HTTP` → `npm:80` (cổng vào proxy cho các site) |

Thay `example.com` bằng domain bạn đã nhập. Không cần publish port trên host; Compose không có mục `ports:`. Tunnel kết nối đến các dịch vụ nội bộ trên Docker network.

Để quản trị Portainer qua `docker.example.com`, tạo thêm Public Hostname `docker.example.com` → `HTTP` → `npm:80`, rồi trong NPM thêm Proxy Host cho `docker.example.com` trỏ đến `https://portainer:9443`, bật Websockets Support. Tạo Proxy Host tương tự cho từng ứng dụng. Trình duyệt truy cập các hostname bằng HTTPS; TLS công khai được Cloudflare xử lý.

NPM và Portainer yêu cầu tạo tài khoản quản trị khi đăng nhập lần đầu. Script không tạo thông tin mặc định. Portainer được cấp Docker socket để quản lý Docker; quyền này có thể tương đương quyền root trên host, nên chỉ quản trị viên đáng tin cậy được truy cập.

Portainer CE là Community Edition. Portainer mô tả CE dành cho homelab/học tập và không dành cho hệ thống kinh doanh hoặc production có yêu cầu uptime, bảo mật hay toàn vẹn dữ liệu; hãy đánh giá giấy phép và hỗ trợ phù hợp trước khi dùng trong production. [Thông tin Portainer CE](https://github.com/portainer/portainer#intended-use)

## Sửa cấu hình sau khi cài

Nếu nhập sai domain hoặc cần đổi Tunnel token, chạy trình quản lý tương tác với quyền root:

```bash
sudo ./manage-config.sh
```

Menu cho phép:

- Sửa domain gốc đã lưu trong `/opt/infra-stack/.env`; sau đó cập nhật Public Hostname tương ứng trong Cloudflare Dashboard.
- Thay Tunnel token bằng cách nhập ẩn; script lưu token vào file secret và khởi động lại riêng `cloudflared`.
- Áp dụng lại Compose và khởi động toàn bộ stack theo cấu hình đã lưu.

Trình quản lý không hiển thị token. Thay đổi domain không tự cập nhật cấu hình Public Hostname trên Cloudflare, vì Tunnel đang được quản lý từ Dashboard.

## Bật/tắt dịch vụ bằng Compose profiles

Mỗi dịch vụ có profile riêng và profile `all`. Dùng `up -d` để khởi động/tạo dịch vụ; dùng `stop` để dừng mà vẫn giữ container và dữ liệu:

```bash
sudo docker compose -f /opt/infra-stack/compose.yaml --profile npm up -d npm
sudo docker compose -f /opt/infra-stack/compose.yaml --profile npm stop npm

sudo docker compose -f /opt/infra-stack/compose.yaml --profile portainer up -d portainer
sudo docker compose -f /opt/infra-stack/compose.yaml --profile portainer stop portainer

sudo docker compose -f /opt/infra-stack/compose.yaml --profile tunnel up -d cloudflared
sudo docker compose -f /opt/infra-stack/compose.yaml --profile tunnel stop cloudflared

# Khởi động hoặc dừng cả ba dịch vụ
sudo docker compose -f /opt/infra-stack/compose.yaml --profile all up -d
sudo docker compose -f /opt/infra-stack/compose.yaml --profile all stop
```

Các profile độc lập: dừng NPM không dừng Portainer hoặc Tunnel. Tuy nhiên, khi dừng Tunnel thì các hostname công khai qua Cloudflare sẽ mất kết nối đến máy chủ.

## Cấu hình và cập nhật

- Compose file đang chạy: `/opt/infra-stack/compose.yaml`.
- Biến cấu hình không bí mật: `/opt/infra-stack/.env`.
- Cloudflare token: `/opt/infra-stack/secrets/cloudflare-tunnel-token`.
- Dữ liệu bền vững: `/srv/infra-data` hoặc đường dẫn `DATA_DIR` đã chọn.

Image tag được ghim trong `compose.yaml`, không dùng `latest`. Để cập nhật, rà soát tag mới và ghi chú migration/backup của từng dịch vụ, sau đó:

```bash
sudo docker compose -f /opt/infra-stack/compose.yaml pull
sudo docker compose -f /opt/infra-stack/compose.yaml up -d
```

Trước khi nâng phiên bản NPM hoặc Portainer, sao lưu thư mục dữ liệu tương ứng. Sao lưu/NAS không được cấu hình tự động bởi repo này.

Script không di chuyển dữ liệu từ các lần cài cũ trong `/home/MEGAT/docker`; hãy sao lưu và lập kế hoạch migration riêng trước khi chạy trên máy đang có stack cũ.
