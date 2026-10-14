# Tự động hoá tạo tệp dữ liệu ngoại tuyến và tải lên máy chủ / Google Drive / GitHub Releases

Tài liệu hướng dẫn tự động hoá toàn bộ quy trình:
1. **Tạo dữ liệu giao thông**: Cập nhật dữ liệu camera phạt nguội & biển báo tốc độ VietMap KC01 mới nhất (`vietnam_cameras.json`, `vietnam_signs.json`, `waze_segments.bin`).
2. **Tạo dữ liệu chỉ đường**: Tải OpenStreetMap extract và build GraphHopper graph (`routing_graph.ghz`).
3. **Tạo bản đồ vector**: Đóng gói PMTiles (`saigon_z16.pmtiles`).
4. **Tạo mã băm phiên bản**: Tự động sinh `version.json` và `manifest.json`.
5. **Đẩy lên máy chủ lưu trữ miễn phí**:
   - **GitHub Releases (Khuyên dùng)**: Máy chủ CDN miễn phí 100%, băng thông không giới hạn, link tải trực tiếp vĩnh viễn, hỗ trợ tải HTTP Range.
   - **Google Drive**: Tải lên thư mục Drive tự động qua `rclone`.
   - **Cloudflare Quick Tunnel**: Mở server local ra internet với link HTTPS công khai miễn phí trong 1 lệnh.

---

## 1. Tự động hoá 100% trên GitHub Actions (Không tốn tài nguyên máy)

Repo đã được thiết lập workflow [`.github/workflows/update_offline_data.yml`](../.github/workflows/update_offline_data.yml):

### Lịch chạy tự động:
- Tự động chạy định kỳ vào **ngày 1 hàng tháng** lúc 03:00 UTC (trùng với lịch phát hành dữ liệu VietMap KC01).

### Chạy thủ công bất cứ lúc nào (1 chạm):
1. Vào tab **Actions** trên GitHub repository: `https://github.com/DangLamTung/navbridge/actions`.
2. Chọn workflow **"Update Offline Data"**.
3. Bấm nút **"Run workflow"**:
   - Chọn vùng GraphHopper: `saigon` (mặc định), `hanoi`, `danang`, hoặc `vietnam`.
   - Bấm **Run**.
4. GitHub runner sẽ tự động build toàn bộ dữ liệu và đẩy vào Release `offline-data-latest`.

### Link tải trực tiếp sau khi phát hành:
- **DATA_URL** (Dữ liệu giao thông tự cập nhật):
  `https://github.com/DangLamTung/navbridge/releases/download/offline-data-latest`
- **Bản đồ vector**:
  `https://github.com/DangLamTung/navbridge/releases/download/offline-data-latest/saigon_z16.pmtiles`
- **Chỉ đường GraphHopper**:
  `https://github.com/DangLamTung/navbridge/releases/download/offline-data-latest/routing_graph.ghz`
- **Phiên bản**:
  `https://github.com/DangLamTung/navbridge/releases/download/offline-data-latest/version.json`

---

## 2. Chạy tự động cục bộ bằng lệnh CLI

Script `tools/update_server.py` đã tích hợp mọi thao tác:

### A. Tạo tất cả dữ liệu (VietMap + GraphHopper + PMTiles) và đẩy lên GitHub Releases:
```bash
# Đặt GitHub Token (hoặc đăng nhập bằng `gh auth login`):
export GITHUB_TOKEN=ghp_your_token_here

# Build cho TP.HCM và đẩy lên GitHub Release:
python3 tools/update_server.py --build-all saigon --upload github

# Hoặc build cho toàn Việt Nam:
python3 tools/update_server.py --build-all vietnam --upload github
```

### B. Đẩy lên Google Drive qua `rclone`:
```bash
# 1. Cài đặt rclone (nếu chưa có):
brew install rclone

# 2. Cấu hình Google Drive (chỉ làm 1 lần):
rclone config
# Đặt tên remote là 'gdrive' và chọn Google Drive.

# 3. Build và đồng bộ lên Google Drive:
python3 tools/update_server.py --build-all saigon --upload gdrive:navbridge_data
```

### C. Chạy server nội bộ và mở public qua Cloudflare Tunnel (Miễn phí):
Nếu muốn điện thoại ở bất cứ đâu (4G/5G/Wi-Fi) kết nối thẳng vào máy tính của bạn:
```bash
# Cài cloudflared (miễn phí):
brew install cloudflared

# Khởi chạy server và tạo link HTTPS công khai:
python3 tools/update_server.py --serve --tunnel --port 8080
```
Server sẽ in ra đường link HTTPS công khai, ví dụ:
```
[tunnel] FREE PUBLIC HTTPS URL: https://funny-random-name.trycloudflare.com
[tunnel] NavBridge DATA_URL:    https://funny-random-name.trycloudflare.com/latest
```
Chỉ cần nhập URL này vào ô **DATA_URL** trong NavBridge là app sẽ tự cập nhật.

---

## 3. Cài đặt định kỳ trên máy tính qua Crontab

Chạy script [`tools/cron_update_vietmap.sh`](../tools/cron_update_vietmap.sh) trong crontab:
```bash
# Mở crontab:
crontab -e

# Thêm dòng sau để tự động kiểm tra và đẩy lên GitHub Release lúc 3h sáng hàng ngày:
0 3 * * * cd /Users/tungdl/Documents/Eink/navbridge && export GITHUB_TOKEN=ghp_... && export UPLOAD_TARGET=github && ./tools/cron_update_vietmap.sh
```

---

## 4. Tạo lại gói ô bản đồ nền (overview tiles)

`assets/offline_map/overview_tiles.tar.gz` là gói ô bản đồ phủ toàn quốc ở mức
thu nhỏ (z0–z8, 171 ô). App chỉ dùng nó khi **ngoại tuyến** hoặc khi nguồn bản
đồ đang chọn tải lỗi — mạng có sẵn thì nguồn đang chọn luôn thắng.

Gói đang phát hành được lấy từ CARTO, và CARTO hiện đóng dấu
"API KEY REQUIRED" lên mọi ô không kèm khoá (đo 2026-10-14: 2 049 B không khoá
so với 20 325 B có khoá), nên trong ảnh bản đồ hiện ra có vệt mờ. Tạo lại bằng:

```bash
python3 tool/build_overview_tiles.py                              # xem trước
python3 tool/build_overview_tiles.py --provider carto --write     # dùng CARTO_API_KEY trong .env
python3 tool/build_overview_tiles.py --provider esri-street --write  # không cần khoá
```

Công cụ đọc **đúng danh sách (z,x,y) của gói cũ** (chỉ đổi nguồn ảnh, không đổi
độ phủ), và tự huỷ — không ghi gì — nếu gặp trang chặn của nhà cung cấp (OSM trả
HTTP 200 kèm ảnh "Access blocked", xem `KNOWN_BLOCK_IMAGES`) hoặc nếu dưới 90%
số ô là ảnh khác nhau. Sau khi tạo, **mở thử một ô** để chắc chắn không còn vệt
mờ, rồi mới phát hành qua `tools/update_server.py`.
