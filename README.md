# Ubuntu / Debian Docker host setup

Công cụ cài Docker Engine, Docker Compose plugin, Nginx Proxy Manager (NPM), Portainer CE và Cloudflare Tunnel. Hỗ trợ Ubuntu Server 22.04/24.04/26.04 LTS, Debian 12/13 và kiến trúc `amd64`/`arm64`.

## Cài đặt

```bash
git clone https://github.com/tungtk0021/ubuntu-deploy.git
cd ubuntu-deploy
chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh

sudo ./deploy-ubuntu.sh
# hoặc
sudo ./deploy-debian.sh
```

Installer sẽ hỏi tên hiển thị, mã Docker và vị trí thư mục dự án bên trong home. Mặc định home là tài khoản đã gọi `sudo` (hoặc `/root` nếu đăng nhập trực tiếp root). Mã dự án chỉ chấp nhận chữ thường, số, `_` và `-`. Tất cả cấu hình, token, dữ liệu, backup và lệnh quản lý được đặt trong thư mục dự án.

Sau đó nhập domain gốc và Cloudflare Tunnel token (token được nhập ẩn). Token lưu trong `secrets/cloudflare-tunnel-token` với quyền hạn chế, tách khỏi `.env` và Compose. Mạng Docker mặc định là `infra_edge` (`10.1.1.0/24`) và `infra_apps` (`10.1.2.0/24`); có thể chỉnh bằng `EDGE_NETWORK`, `APP_NETWORK`, `EDGE_SUBNET`, `APP_SUBNET` trước khi chạy.

Nếu dự định đặt dữ liệu trên volume/NAS, hãy mount volume đó trước và chọn thư mục dự án nằm trên volume được mount. Installer không tự chỉnh `/etc/fstab` hay mount NAS. Không có cổng dịch vụ nào được publish trực tiếp lên host; Cloudflare Tunnel kết nối qua Docker network.

## Các lệnh trong thư mục dự án

- `sudo ./start.sh` khởi động toàn bộ dịch vụ của dự án.
- `sudo ./stop.sh` dừng toàn bộ dịch vụ, giữ container và dữ liệu.
- `sudo ./manage.sh` mở menu quản trị dự án.
- `compose.yaml`, `.env`, `secrets/`, `data/`, `backups/` nằm cạnh các lệnh trên.

Các lệnh này chỉ dùng Compose project name đã lưu của dự án đó, nên không dừng stack Docker khác trên máy.

## Menu quản trị

Menu `manage.sh` hỗ trợ:

1. Sửa domain (cần cập nhật Public Hostname thủ công trong Cloudflare Dashboard).
2. Thay token Cloudflare và tạo lại riêng connector Tunnel.
3. Áp dụng cấu hình Compose và khởi động toàn bộ dịch vụ.
4. Đổi tên hiển thị, mã Docker và/hoặc vị trí thư mục trong cùng home. Stack sẽ dừng và được chuyển; khởi động lại bằng `start.sh` tại vị trí mới.
5. Khôi phục dữ liệu NPM, Let’s Encrypt và Portainer từ một thư mục dự án cũ. Hỗ trợ cấu trúc `npm/data`, `npm/letsencrypt`, `portainer` và `data/npm/data`, `data/npm/letsencrypt`, `data/portainer`. Dữ liệu hiện tại được giữ tại `backups/pre-restore-*`; stack để dừng sau khi khôi phục để quản trị viên kiểm tra rồi chủ động start. Token Tunnel và cấu hình Compose của nguồn cũ không được nhập.
6. Xóa trắng dự án, bao gồm dữ liệu, token và backups. Yêu cầu gõ `WIPE <mã-dự-án>`; thao tác này không thể hoàn tác.

Đổi tên và khôi phục cũng yêu cầu cụm xác nhận được menu hiển thị. Trình quản lý không hiển thị token.

## Cloudflare hostname

Trong Cloudflare Zero Trust → Networks → Tunnels → chọn Tunnel → Public Hostnames, thêm:

| Hostname | Service |
| --- | --- |
| `proxy.example.com` | `HTTP` → `npm:81` |
| `example.com` | `HTTP` → `npm:80` |

Thay `example.com` bằng domain đã nhập. Muốn quản trị Portainer qua `docker.example.com`, tạo thêm hostname đến `npm:80`, sau đó cấu hình Proxy Host trong NPM trỏ đến `https://portainer:9443` và bật Websockets Support. Trình duyệt dùng HTTPS công khai qua Cloudflare.

NPM và Portainer yêu cầu tạo tài khoản quản trị ở lần đăng nhập đầu tiên. Portainer được cấp Docker socket, quyền này gần tương đương root trên host; chỉ cho quản trị viên tin cậy truy cập. Portainer CE hướng tới homelab/học tập; hãy đánh giá giấy phép và hỗ trợ phù hợp trước khi dùng production. [Portainer CE](https://github.com/portainer/portainer#intended-use)

## Dịch vụ riêng lẻ và cập nhật

Mỗi dịch vụ có Compose profile riêng (`npm`, `portainer`, `tunnel`) và profile `all`. Dùng thư mục dự án thực tế thay cho `<PROJECT_DIR>`:

```bash
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm up -d npm
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm stop npm
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all pull
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all up -d
```

Image tag được ghim trong `compose.yaml`, không dùng `latest`. Trước khi nâng NPM hoặc Portainer, sao lưu thư mục dữ liệu tương ứng. Sao lưu/NAS tự động chưa được cấu hình.
