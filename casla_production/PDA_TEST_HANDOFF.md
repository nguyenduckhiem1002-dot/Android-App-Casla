# PDA test — 2026-09-07

## Artifact

- `build/pda-test/Casla-PDA-TEST-1.0.0-build2.apk`
- Version 1.0.0, versionCode 2; package `com.example.casla_production`.
- Android 7.0/API 24 trở lên; ARM 32-bit, ARM64 và x86_64.
- **APK debug test nội bộ, không phải production release.** Build dùng cấu hình direct-SAP hiện tại, có shared Basic credential trong binary. Chỉ giao thiết bị/người kiểm thử được phép; không upload công khai. Không dùng debug build để kết luận hiệu năng release.
- SHA-256: `2A50BA933B5273E55B4E9995794E8E253B99C53A004226A6FD4177A1D13E4CEA`.

Chép APK vào PDA rồi mở để cài. Nếu báo khác chữ ký, không gỡ app ngay: cần bảo toàn các giao dịch chưa đồng bộ và kiểm tra bản đã cài trước. Bản này dùng cùng package, không phải ứng dụng sandbox dữ liệu riêng; thao tác ghi có thể gửi đến SAP đã cấu hình.

## Đã kiểm tra lần này

- `flutter analyze --no-pub`: không có issue.
- `flutter test --no-pub`: 209 test pass.
- `flutter build apk --debug --flavor production --no-pub --build-number=2 --dart-define-from-file=.env`: thành công.
- Layout Tổng quan có test màn ngang, chữ hệ thống 200%, lịch Từ ngày/Đến ngày và áp dụng khoảng ngày.
- KPI không còn bị ép chiều cao; bộ lọc và nội dung có thể cuộn trên màn thấp. Chữ lớn chuyển KPI sang một cột.
- Migration có test bảo toàn dữ liệu khi cột đã tồn tại, tránh lỗi duplicate column gây kẹt khởi động.

Chưa kiểm thử bản APK này trên PDA thật; test widget không thay thế kiểm thử thiết bị có dữ liệu thực, bàn phím và scanner hãng.

## Còn cần hoàn thiện — theo ưu tiên

1. **P0, release chính thức:** `android/app/build.gradle.kts` yêu cầu application ID, keystore và gateway SAP. `android/key.properties` hiện không có; `.env` hiện chứa Basic auth và không khai báo gateway. `lib/core/config/app_config.dart` loại Basic credential khỏi release runtime. Không thể biến APK hiện tại thành release đăng nhập được chỉ bằng đổi cờ build; cần cấu hình ký/gateway hợp lệ, không bỏ guard.
2. **P1, biên khoảng ngày:** `s06_supervisor_overview_screen.dart` kiểm tra `difference.inDays > 31`, cho phép 32 ngày nếu tính cả hai đầu, trong khi thông báo tối đa 31 ngày. Nên thống nhất quy tắc inclusive dùng chung cho Overview/History và thêm test 31/32 ngày. Chưa sửa trong lần đóng gói này.
3. **P1, dữ liệu lịch sử lớn:** contract EDMX người dùng cung cấp xác định `getWorkHistory` là bound action, tham số gồm AccessToken, DeviceID, RangeCode, DateFrom, DateTo, WorkerID, SummaryOnly; không có cursor/page size. Gateway hiện POST action rồi parse toàn bộ `_Entries`. Cần thống nhất contract phân trang backend trước khi thêm tải từng trang mạng; không tự gắn `$skip/$top` vào action. Cache và phân trang hiển thị không thay thế phân trang mạng.
4. **P1, scanner PDA:** `CipherLabBroadcastPolicy.acceptsSender` không xác minh được sender trên API <34; kiểm thử firmware thực và dùng MDM hạn chế app lạ. Android 14+ cũng cần xác nhận Reader Service thực đi qua allowlist. Xem `android/SCANNER_SECURITY.md`.
5. **P2, toolchain:** build cảnh báo device_info_plus/mobile_scanner còn áp dụng Kotlin Gradle Plugin. Lên đợt nâng plugin riêng kèm test scanner, không nâng gấp trước pilot.

## Checklist PDA

- Mở app/cập nhật không kẹt splash; đăng nhập lại.
- Tổng quan: tổ, hôm nay/hôm qua, tuần, tháng và khoảng ngày; dữ liệu nhiều công nhân/tên dài.
- Màn dọc/ngang, tăng chữ, mở lịch và bàn phím: không sọc overflow.
- QR công nhân chưa đến hạn/hết hạn bị từ chối; QR công đoạn hiển thị tên hàng.
- Scanner trigger liên tục, sleep/resume, camera fallback.
- Offline → tạo giao dịch → đóng/mở app → kết nối lại → xác minh mật khẩu → SAP ACK, không ghi trùng.
- Chỉ dùng tài khoản và dữ liệu được phép kiểm thử; giao dịch ghi không phải mô phỏng.
