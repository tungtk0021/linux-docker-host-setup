# Ubuntu / Debian Docker host setup

Công cụ cài Docker Engine, Docker Compose plugin, Nginx Proxy Manager (NPM), Portainer CE và Cloudflare Tunnel. Hỗ trợ Ubuntu Server 22.04/24.04/26.04 LTS, Debian 12/13 và kiến trúc `amd64`/`arm64`.

## Cài đặt nhanh

```bash
sudo apt-get update && sudo apt-get install -y git
```

Clone lần đầu:

```bash
git clone https://github.com/tungtk0021/linux-docker-host-setup.git
cd linux-docker-host-setup
```

Thư mục clone đã tồn tại:

```bash
cd ~/linux-docker-host-setup
git fetch origin
git checkout main
git pull --ff-only origin main
```

Chạy cài đặt:

```bash
chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh update-project.sh remove-legacy.sh remove-project.sh
sudo ./deploy-ubuntu.sh
# hoặc
sudo ./deploy-debian.sh
```

## Trước khi cài: thư mục dự án đã tồn tại

Installer không ghi đè một thư mục đích có sẵn nếu thư mục đó chưa được đánh dấu là dự án do công cụ này quản lý. Nếu gặp thông báo thư mục đã tồn tại:

- **Đó là dự án đã cài bằng installer này:** nhập lại đúng home, đường dẫn và mã dự án đã lưu. Installer nhận diện qua `.project-managed`, giữ `data/` và token hiện tại, rồi cập nhật cấu hình. Để cập nhật code thường ngày, dùng `update-project.sh` như hướng dẫn bên dưới.
- **Đó là thư mục cũ hoặc do bạn tự tạo:** trước tiên xem nội dung, ví dụ `sudo ls -la /duong/dan/du-an` và `sudo du -sh /duong/dan/du-an`. Nếu có dữ liệu cần giữ, không xóa thư mục; chọn một thư mục đích mới cho bản cài và dùng chức năng khôi phục dữ liệu sau khi cài. Nếu thư mục hoàn toàn rỗng, có thể chọn đường dẫn mới hoặc xóa riêng thư mục rỗng rồi chạy lại.
- **Đó là dự án được quản lý nhưng bạn nhập mã khác:** không chạy installer với mã mới tại đó. Mở `sudo <đường-dẫn-dự-án>/manage.sh`, chọn đổi mã/tên/vị trí, rồi dùng đường dẫn và mã mới mà menu đã lưu.

Không xóa một thư mục chỉ vì installer từ chối dùng nó. Các thư mục cũ có thể chứa dữ liệu NPM, chứng chỉ, token hoặc backup; hãy xác minh và sao lưu trước khi dọn.

## Cài đặt

Clone repo từ tài khoản GitHub của bạn rồi chuyển vào thư mục clone:

```bash
chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh update-project.sh remove-legacy.sh remove-project.sh

sudo ./deploy-ubuntu.sh
# hoặc
sudo ./deploy-debian.sh
```

Installer chỉ hỏi tên thư mục dự án, ví dụ `pn-tech`; thư mục sẽ được tạo thành `/home/pn-tech`. Tên Docker mặc định lấy theo tên thư mục. Tên hiển thị, domain và Cloudflare Tunnel token được hỏi riêng. Khi cài lại dự án, domain hiện tại được hiển thị làm gợi ý: nhấn Enter để giữ, hoặc nhập domain mới để thay. Nếu chưa có domain cũ, Enter giữ trạng thái chưa cấu hình (hoặc giá trị mặc định). Với Tunnel token đã lưu, ô nhập token được để trống: nhấn Enter để giữ token cũ, hoặc nhập token mới để thay; token không bao giờ được in ra màn hình. Mỗi câu hỏi ghi rõ trong ngoặc cách dùng Enter và giá trị mặc định; domain/token dùng ví dụ giữ chỗ `example.domain.com` và `example.tokens`. Giá trị mặc định nằm trong `project-defaults.conf`. Sau khi cài thành công, `global-config.conf` tại gốc source repo lưu các giá trị mặc định và danh sách từng dự án kèm đường dẫn tới file cấu hình riêng. Mỗi dự án có `project-config.conf` bên cạnh `.env`; cả hai file không chứa Tunnel token. Global config và file cấu hình dự án được cập nhật khi thay đổi cấu hình, đổi vị trí hoặc xóa dự án. Token vẫn nằm riêng trong `secrets/` của dự án.

Installer lưu tiến trình sau mỗi bước vào `install-progress.conf` tại gốc source repo. Nếu nhập sai hoặc cài đặt bị gián đoạn, chạy lại cùng lệnh deploy để tiếp tục từ câu hỏi/bước chưa hoàn tất; các câu trả lời hợp lệ trước đó được giữ lại. File tiến trình được đặt quyền chỉ root đọc và không lưu token. Token được ghi ngay vào file secrets riêng với quyền hạn chế khi nhập; sau khi triển khai thành công, file tiến trình tự được xóa.

Nếu dự án đã có token, nhấn Enter ở câu hỏi giữ token để dùng lại. Ở lần cài mới, không có token Cloudflare mặc định được nhúng trong repo; nhấn Enter ở ô token sẽ cài và chạy NPM/Portainer, đồng thời để Tunnel tắt. Có thể thêm token sau trong `manage.sh` → “Thay Cloudflare Tunnel token”; lần start tiếp theo sẽ chạy Tunnel. Token nhập được ẩn và lưu riêng trong `secrets/cloudflare-tunnel-token`, không nằm trong `.env` hoặc Compose.

Các subnet trên chỉ là giá trị mẫu; kiểm tra chúng không trùng LAN, VPN hoặc Docker network khác. Có thể ghi đè bằng `EDGE_NETWORK`, `APP_NETWORK`, `EDGE_SUBNET`, `APP_SUBNET` trước khi chạy.

Installer chỉ chấp nhận Ubuntu Server 22.04/24.04/26.04 LTS và Debian 12/13 chạy systemd; Ubuntu 20.04 và bản khác sẽ bị từ chối sớm. Một số lệnh nền hoặc tùy chọn có thể vắng mặt trên bản Minimal/phiên bản cũ: installer kiểm tra các lệnh cần thiết và báo gói APT đề xuất (`coreutils`, `mawk`, `sed`, `passwd`, `libc-bin`, `dpkg`, `findutils`) thay vì tiếp tục với lỗi khó hiểu. Nếu thiếu `curl`, installer thử cài; Git là tùy chọn. Nếu lúc cập nhật chọn tải code mà máy thiếu `tar`, cài bằng `sudo apt-get install tar`; lần start hiện tại vẫn tiếp tục với code cũ. Docker Compose plugin được kiểm tra trước khi dùng.

Nếu dự định đặt dữ liệu trên volume/NAS, hãy mount volume đó trước và chọn thư mục dự án nằm trên volume được mount. Installer không tự chỉnh `/etc/fstab` hay mount NAS. Không có cổng dịch vụ nào được publish trực tiếp lên host; Cloudflare Tunnel kết nối qua Docker network.

## Các lệnh trong thư mục dự án

- `sudo ./start.sh` kiểm tra GitHub rồi khởi động toàn bộ dịch vụ của dự án.
- `sudo ./stop.sh` dừng toàn bộ dịch vụ, giữ container và dữ liệu.
- `sudo ./manage.sh` mở menu quản trị dự án.
- `compose.yaml`, `.env`, `secrets/`, `data/`, `backups/` nằm cạnh các lệnh trên.

Các lệnh này chỉ dùng Compose project name đã lưu của dự án đó, nên không dừng stack Docker khác trên máy.

## Tổng hợp lệnh dự án

Thay `<PROJECT_DIR>` bằng đường dẫn thư mục cài đặt và `<PROJECT_SLUG>` bằng mã Docker đã chọn.

| Lệnh | Tác dụng |
| --- | --- |
| `sudo apt-get update && sudo apt-get install -y git` | Cài Git trên Ubuntu/Debian. |
| `git clone https://github.com/tungtk0021/linux-docker-host-setup.git` | Tải source lần đầu; tạo thư mục `linux-docker-host-setup`. |
| `cd ~/linux-docker-host-setup` | Chuyển vào thư mục source đã clone. |
| `git fetch origin` | Lấy thông tin commit mới từ GitHub. |
| `git checkout main` | Chuyển sang nhánh chính. |
| `git pull --ff-only origin main` | Cập nhật source theo nhánh `main`, không tạo merge commit. |
| `chmod +x deploy-ubuntu.sh deploy-debian.sh manage-config.sh update-project.sh remove-legacy.sh remove-project.sh` | Cấp quyền chạy cho các script. |
| `sudo ./deploy-ubuntu.sh` | Cài stack trên Ubuntu Server. |
| `sudo ./deploy-debian.sh` | Cài stack trên Debian. |
| `sudo ./start.sh` | Kiểm tra cập nhật GitHub rồi khởi động toàn bộ dự án. |
| `sudo ./stop.sh` | Dừng toàn bộ dịch vụ, giữ dữ liệu và container. |
| `sudo ./manage.sh` | Mở menu quản trị domain, Tunnel, cấu hình, đổi vị trí, khôi phục hoặc xóa trắng. |
| `sudo ./remove-project.sh` | Liệt kê container đang chạy; chọn gỡ một dự án, gỡ toàn bộ container trên máy, hoặc thoát. Gỡ toàn máy cần gõ xác nhận và giữ volumes/dữ liệu. |
| `sudo ./update-project.sh <PROJECT_DIR>` | Cập nhật template của dự án đã cài; giữ `.env`, token và dữ liệu. Có thể thêm `[commit] [branch]` để chỉ định nguồn cập nhật. |
| `sudo ./remove-legacy.sh` | Liệt kê container đang chạy; chọn dừng/gỡ riêng stack cũ, gỡ toàn bộ container trên máy, hoặc thoát. |
| `sudo ./remove-legacy.sh --remove-config-only /opt/infra-stack` | Xóa riêng cấu hình bản cũ đã dừng; dữ liệu bind mount được giữ lại. |
| `sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm up -d npm` | Khởi động riêng NPM. |
| `sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm stop npm` | Dừng riêng NPM. |
| `sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all pull` | Tải image cho toàn bộ dịch vụ. |
| `sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all up -d` | Khởi động toàn bộ dịch vụ theo cấu hình Compose hiện tại. |

## Gỡ dự án theo global config

Chạy `sudo ./remove-project.sh` từ gốc source repo. Script liệt kê các container đang chạy trước, rồi cho chọn tiếp tục gỡ một dự án, dừng/xóa tất cả container trên máy, hoặc thoát. Lựa chọn gỡ toàn máy yêu cầu gõ `REMOVE ALL CONTAINERS`; chỉ container đang chạy tại thời điểm liệt kê bị xóa, volumes, image và dữ liệu bind mount vẫn được giữ. Khi tiếp tục gỡ riêng, script liệt kê dự án từ `global-config.conf`, đọc file `project-config.conf` tương ứng và cho chọn dừng/gỡ container nhưng giữ cấu hình/dữ liệu; xóa toàn bộ dự án sau khi gõ xác nhận; hoặc mở `manage.sh`. Bản cài cũ dùng `remove-legacy.sh`, có cùng lựa chọn gỡ toàn máy.

Khi có commit mới trên nhánh GitHub của dự án, `start.sh` cho chọn cập nhật ngay, hoãn 7 ngày, bỏ qua commit đó cho tới khi có commit mới, bỏ qua một lần hoặc thoát mà không start. Nếu bỏ qua trong 7 ngày thì các cập nhật mới khác cũng sẽ không được hỏi trong thời gian đó. Kiểm tra cần kết nối internet và `curl`; nếu GitHub không phản hồi, script tiếp tục khởi động phiên bản hiện tại. Chạy không có terminal tương tác cũng bỏ qua câu hỏi và start bình thường.

## Menu quản trị

Menu `manage.sh` hỗ trợ:

1. Sửa domain (cần cập nhật Published application route trong Cloudflare Dashboard).
2. Thay token Cloudflare và tạo lại riêng connector Tunnel.
3. Áp dụng cấu hình Compose và khởi động toàn bộ dịch vụ.
4. Đổi tên hiển thị, mã Docker và/hoặc vị trí thư mục trong cùng home. Stack sẽ dừng và được chuyển; khởi động lại bằng `start.sh` tại vị trí mới.
5. Khôi phục dữ liệu NPM, Let’s Encrypt và Portainer từ một thư mục dự án cũ. Hỗ trợ cấu trúc `npm/data`, `npm/letsencrypt`, `portainer` và `data/npm/data`, `data/npm/letsencrypt`, `data/portainer`. Dữ liệu hiện tại được giữ tại `backups/pre-restore-*`; stack để dừng sau khi khôi phục để quản trị viên kiểm tra rồi chủ động start. Token Tunnel và cấu hình Compose của nguồn cũ không được nhập.
6. Xóa trắng dự án, bao gồm dữ liệu, token và backups. Yêu cầu gõ `WIPE <mã-dự-án>`; thao tác này không thể hoàn tác.

Đổi tên và khôi phục cũng yêu cầu cụm xác nhận được menu hiển thị. Trình quản lý không hiển thị token.

## Chuyển từ bản cài cũ

Bản cài cũ chưa có dấu `.project-managed`; không dùng chức năng xóa trắng trong `manage.sh` cho bản cũ. Trước khi chuyển, sao lưu cả thư mục cấu hình cũ (thường là `/opt/infra-stack`) và thư mục dữ liệu (thường là `/srv/infra-data`). Sau đó:

1. Chạy `sudo ./remove-legacy.sh`. Script liệt kê container đang chạy; chọn gỡ stack cũ hoặc gỡ tất cả container trên máy. Khi chọn stack cũ, nhập thư mục Compose và đúng Compose project name mà `docker compose ls --all` hiển thị. Hỗ trợ `compose.yaml`, `compose.yml`, `docker-compose.yaml` và `docker-compose.yml`. Xác nhận `STOP <tên>` để dừng/gỡ riêng stack. Lệnh không gỡ Docker Engine, external networks hoặc dữ liệu bind mount; Compose có thể xóa network riêng do project quản lý.
2. Cài bản mới bằng `deploy-ubuntu.sh` hoặc `deploy-debian.sh`, chọn thư mục dự án mới và nhập token Tunnel.
3. Trong `sudo <thư-mục-dự-án>/manage.sh`, chọn khôi phục dữ liệu từ thư mục cũ, ví dụ `/srv/infra-data`. Dữ liệu hiện tại của dự án mới được giữ trong `backups/`; stack để dừng sau khi khôi phục.
4. Chạy `sudo <thư-mục-dự-án>/start.sh` và kiểm tra NPM, chứng chỉ, Portainer cùng hostname trước khi dọn bản cũ.
5. Chạy `sudo ./remove-legacy.sh --remove-config-only /opt/infra-stack` nếu muốn xóa riêng thư mục cấu hình/token cũ sau khi bản mới đã được kiểm tra. Script kiểm tra không còn container mang project label đó, hỏi xác nhận lần nữa và không xóa `DATA_DIR`. Nếu không thể xác định `DATA_DIR`, script từ chối xóa cấu hình.

Không xóa `/srv/infra-data` cho tới khi đã xác nhận bản mới hoạt động và có bản sao lưu độc lập. Giữ lại Docker networks nếu dự án mới dùng cùng tên/subnet; script gỡ bản cũ không xóa networks.

## Cập nhật dự án đã cài

Lấy phiên bản mới của repo bằng Git, rồi chạy updater với đường dẫn tuyệt đối của dự án hiện tại:

```bash
cd ~/linux-docker-host-setup
git fetch origin
git checkout main
git pull --ff-only origin main
sudo ./update-project.sh /home/USER/PROJECT_SLUG
```

Nhánh chính để cài và nhận cập nhật là `main`. Nếu `git` chưa có trên máy chủ, cài bằng `sudo apt-get update && sudo apt-get install -y git` trước khi cập nhật repo. Git không bắt buộc để chạy stack hoặc kiểm tra bản mới lúc start; việc kiểm tra tự dùng GitHub HTTPS.

Updater xác nhận dự án qua `.project-managed`, sao lưu Compose và công cụ quản trị cũ vào `backups/pre-update-*`, kiểm tra cấu hình, tải image và áp dụng Compose. `.env`, token và `data/` được giữ nguyên. Nếu kiểm tra cấu hình hoặc tải image thất bại, template trước cập nhật được phục hồi. Nếu `up` lỗi giữa lúc áp dụng, kiểm tra log và bản lưu trước khi thử lại.

Updater chỉ cập nhật template có trong repo và image tag được khai báo tại `compose.yaml`; nó không tự thay đổi tag. Đọc release notes và ghi chú migration của dịch vụ trước khi nâng phiên bản có thay đổi schema. `start.sh` dùng cùng updater khi chọn cập nhật từ GitHub.

## Cloudflare Tunnel và ứng dụng public

Trong Cloudflare Dashboard, mở **Networking → Tunnels**, chọn Tunnel của bạn, vào tab **Routes**, chọn **Add route → Published application**. Trong phần Hostname, chọn domain đang quản lý tại Cloudflare và nhập subdomain. Ở **Service URL**, nhập địa chỉ dịch vụ bên trong Docker network:

| Hostname | Service |
| --- | --- |
| `proxy.example.com` | `http://npm:81` |
| `example.com` | `http://npm:80` |
| `portainer.example.com` | `http://portainer:9000` |

Thay `example.com` bằng zone của bạn. Cloudflare Tunnel và Portainer cùng nối vào Docker network `infra_edge`, nên trỏ thẳng tới `http://portainer:9000`; không cần Proxy Host NPM ở giữa hay bật **No TLS Verify**. HTTPS phía ngoài do Cloudflare phục vụ. Tunnel/NPM cũng dùng network này để truy cập dịch vụ `npm`. Cloudflare tạo DNS route cho hostname đã publish; không cần mở cổng dịch vụ trên router hoặc host.

Cloudflare có thể tạo Tunnel mới tại **Networking → Tunnels → Create a tunnel**. Khi Tunnel đã kết nối, thêm route theo các bước trên. Xem [hướng dẫn Cloudflare tạo Tunnel và Published application route](https://developers.cloudflare.com/tunnel/get-started/).

### Khởi tạo tài khoản admin và API token của Portainer

Ở lần cài mới, Portainer từ phiên bản 2.43 yêu cầu **Setup token** một lần để tạo tài khoản admin đầu tiên. Trên Ubuntu/Debian, chạy lệnh dưới đây trong terminal của máy chủ; lệnh tự tìm container Portainer của dự án và in ra dòng token:

```bash
sudo docker logs "$(sudo docker ps --filter label=com.docker.compose.service=portainer --format '{{.Names}}' | head -n1)" 2>&1 | grep -o 'setup_token=[^[:space:]]*' | tail -n1 | cut -d= -f2-
```

Lệnh trên chỉ in giá trị token, không kèm tiền tố `setup_token=`; dán nguyên giá trị đó vào ô **Setup token** trong trình duyệt, rồi tạo tài khoản admin (mặc định username `admin`, mật khẩu tối thiểu 12 ký tự). Token chỉ dùng một lần; không gửi token cho người khác hoặc lưu vào repo. Hoàn tất trong vòng 5 phút kể từ lúc Portainer khởi động; nếu hết thời gian, khởi động lại dịch vụ để tạo token mới:

```bash
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile portainer restart portainer
```

Để tạo **API access token** sau khi đăng nhập: chọn tên tài khoản ở góc trên bên phải → **My account** → **Access tokens** → **Add access token**. Nhập lại mật khẩu để xác nhận, đặt mô tả, rồi sao chép token ngay vì Portainer không hiển thị lại sau đó. Đây là token dùng gọi API, khác với Setup token và mật khẩu admin; không cần thiết cho đăng nhập giao diện. Ví dụ gọi API (thay hostname; nhập token ẩn khi được hỏi):

```bash
read -rsp 'Portainer API token: ' PORTAINER_API_KEY; printf '\n'
curl --fail --silent --show-error -H "X-API-Key: ${PORTAINER_API_KEY}" https://portainer.example.com/api/stacks
unset PORTAINER_API_KEY
```

Portainer được cấp Docker socket, quyền này gần tương đương root trên host; chỉ cho quản trị viên tin cậy truy cập. Portainer CE hướng tới homelab/học tập; hãy đánh giá giấy phép và hỗ trợ phù hợp trước khi dùng production. [Portainer CE](https://github.com/portainer/portainer#intended-use)

## Dịch vụ riêng lẻ và cập nhật

Mỗi dịch vụ có Compose profile riêng (`npm`, `portainer`, `tunnel`) và profile `all`. Dùng thư mục dự án thực tế thay cho `<PROJECT_DIR>`:

```bash
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm up -d npm
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile npm stop npm
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all pull
sudo docker compose -p <PROJECT_SLUG> -f <PROJECT_DIR>/compose.yaml --profile all up -d
```

Image tag được ghim trong `compose.yaml`, không dùng `latest`. Trước khi nâng NPM hoặc Portainer, sao lưu thư mục dữ liệu tương ứng. Sao lưu/NAS tự động chưa được cấu hình.
