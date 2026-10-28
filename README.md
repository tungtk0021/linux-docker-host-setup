# Ubuntu / Debian Docker host setup

Công cụ cài Docker Engine, Docker Compose plugin, Nginx Proxy Manager (NPM), Portainer CE và Cloudflare Tunnel. Hỗ trợ Ubuntu Server 22.04/24.04/26.04 LTS, Debian 12/13 và kiến trúc `amd64`/`arm64`.

## Cài đặt

```bash
git clone https://github.com/tungtk0021/ubuntu-deploy.git
cd ubuntu-deploy
chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh update-project.sh remove-legacy.sh

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

## Chuyển từ bản cài cũ

Bản cài cũ chưa có dấu `.project-managed`; không dùng chức năng xóa trắng trong `manage.sh` cho bản cũ. Trước khi chuyển, sao lưu cả thư mục cấu hình cũ (thường là `/opt/infra-stack`) và thư mục dữ liệu (thường là `/srv/infra-data`). Sau đó:

1. Chạy `sudo ./remove-legacy.sh`. Nhập thư mục Compose cũ và đúng Compose project name mà `docker compose ls --all` hiển thị. Xác nhận `STOP <tên>` để dừng/gỡ container cũ. Lệnh không gỡ Docker Engine, external networks hoặc dữ liệu bind mount; Compose có thể xóa network riêng do project quản lý.
2. Cài bản mới bằng `deploy-ubuntu.sh` hoặc `deploy-debian.sh`, chọn thư mục dự án mới và nhập token Tunnel.
3. Trong `sudo <thư-mục-dự-án>/manage.sh`, chọn khôi phục dữ liệu từ thư mục cũ, ví dụ `/srv/infra-data`. Dữ liệu hiện tại của dự án mới được giữ trong `backups/`; stack để dừng sau khi khôi phục.
4. Chạy `<thư-mục-dự-án>/start.sh` và kiểm tra NPM, chứng chỉ, Portainer cùng hostname trước khi dọn bản cũ.
5. Chạy `sudo ./remove-legacy.sh --remove-config-only /opt/infra-stack` nếu muốn xóa riêng thư mục cấu hình/token cũ sau khi bản mới đã được kiểm tra. Script kiểm tra không còn container mang project label đó, hỏi xác nhận lần nữa và không xóa `DATA_DIR`. Nếu không thể xác định `DATA_DIR`, script từ chối xóa cấu hình.

Không xóa `/srv/infra-data` cho tới khi đã xác nhận bản mới hoạt động và có bản sao lưu độc lập. Giữ lại Docker networks nếu dự án mới dùng cùng tên/subnet; script gỡ bản cũ không xóa networks.

## Cập nhật dự án đã cài

Lấy phiên bản mới của repo bằng Git, rồi chạy updater với đường dẫn tuyệt đối của dự án hiện tại:

```bash
cd ~/ubuntu-deploy
git fetch origin
git switch codex/ubuntu-debian-rework
git pull --ff-only
sudo ./update-project.sh /home/USER/PROJECT_SLUG
```

Nhánh có script updater hiện tại là `codex/ubuntu-debian-rework`. Nếu nhánh này được merge vào nhánh mặc định sau đó, có thể cập nhật theo nhánh mặc định thay cho lệnh `git switch` ở trên.

Updater xác nhận dự án qua `.project-managed`, sao lưu Compose và công cụ quản trị cũ vào `backups/pre-update-*`, kiểm tra cấu hình, tải image và áp dụng Compose. `.env`, token và `data/` được giữ nguyên. Nếu kiểm tra cấu hình hoặc tải image thất bại, template trước cập nhật được phục hồi. Nếu `up` lỗi giữa lúc áp dụng, kiểm tra log và bản lưu trước khi thử lại.

Updater chỉ cập nhật template có trong repo và image tag được khai báo tại `compose.yaml`; nó không tự thay đổi tag. Đọc release notes và ghi chú migration của dịch vụ trước khi nâng phiên bản có thay đổi schema.

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
