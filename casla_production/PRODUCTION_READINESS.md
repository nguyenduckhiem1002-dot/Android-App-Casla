# Kế hoạch đưa Casla Production lên môi trường thật

## Trạng thái hiện tại

Ứng dụng đã có kiểm tra format, analyze, test và build iOS không ký trên CI. Tuy
nhiên dữ liệu nghiệp vụ vẫn là bộ nhớ tạm (`CaslaDatabase`), chưa có sync worker
thật và cơ chế xác thực hiện vẫn cần tài khoản Basic SAP đóng gói qua
`dart-define`. Vì vậy bản hiện tại chưa đủ điều kiện phát hành production.

## P0 — Điều kiện bắt buộc trước pilot

### 1. Chốt hợp đồng bảo mật SAP/API

- Không đóng gói `SAP_BASIC_AUTH_USER` hoặc `SAP_BASIC_AUTH_PASSWORD` trong
  APK/IPA. Đặt service credential tại SAP API Management/BTP/gateway backend.
- Mobile đăng nhập qua gateway và chỉ nhận access token ngắn hạn; refresh token
  phải được xoay vòng và có khả năng thu hồi.
- Truyền token bằng `Authorization: Bearer`, không truyền token/mật khẩu trong
  query string. Query string có thể xuất hiện trong proxy, gateway và crash log.
- Response hồ sơ người dùng phải có các claim: `Role`, `Permissions`, `TeamIds`.
  App hiện fail-closed nếu thiếu các claim này.
- SAP/backend phải kiểm tra quyền và phạm vi tổ ở mọi API ghi dữ liệu. Kiểm tra
  phía Flutter chỉ phục vụ UX, không phải ranh giới bảo mật.
- Bật HTTPS với certificate hợp lệ; xác nhận chính sách certificate rotation và
  không dùng bypass TLS.

### 2. Thay in-memory store bằng SQLite

- Dùng Drift/SQLite, có schema version và migration tự động.
- Các giao dịch `entity + sync_queue + audit_log` phải nằm trong một transaction.
- Tạo index tối thiểu cho `assignmentId`, `workerId`, `teamId`, `businessDate`,
  `syncStatus`, `createdAtUtc` và `idempotencyKey` unique.
- Lưu access/refresh token trong Android Keystore/iOS Keychain; không lưu trong
  SQLite hoặc log.
- Viết test thật cho quy trình: offline → tắt process → mở lại → sync → SAP ACK.
- Chỉ xóa queue item sau khi SAP xác nhận thành công; retry dùng exponential
  backoff, jitter và giới hạn số lần thử.

### 3. Master data và quyền truy cập

- Cung cấp API đồng bộ nhân viên, tổ, đơn hàng và phạm vi supervisor.
- QR chỉ mang mã định danh. Tên, vai trò và phạm vi phải lấy từ master data đã
  xác thực.
- Chốt mapping permission: `VIEW_TEAM_PRODUCTION`, `ASSIGN_QUANTITY`,
  `RECALL_ASSIGNMENT`, `VIEW_EMPLOYEE_HISTORY`, `VIEW_SYNC_STATUS`, `SWITCH_USER`.
- Chốt chính sách session timeout, khóa tài khoản, rate limit và đổi mật khẩu.

## P1 — Build, signing và phân phối

### Android

- Chọn Application ID chính thức, ví dụ `com.casla.production`; đổi cả namespace
  và package của `MainActivity`.
- Tạo upload keystore riêng, lưu file/password/alias trong GitHub Environment
  secrets; không commit keystore hoặc `key.properties`.
- Cấu hình Play App Signing và build `appbundle` cho Play Console.
- Tạo flavor `dev`, `staging`, `production` với Application ID và API URL riêng.

### iOS

- Chọn Bundle ID chính thức, ví dụ `com.casla.production`.
- Cần Apple Developer Team ID, Apple Distribution certificate `.p12`, mật khẩu
  `.p12`, App Store provisioning profile và App Store Connect API key.
- Lưu các giá trị trên trong GitHub Environment `production`; cấu hình
  `flutter build ipa` và upload TestFlight.
- Không dùng `--no-codesign` cho job phân phối; job đó chỉ dùng kiểm tra compile.

## P1 — CI/CD và vận hành

- Flutter CI được ghim ở `3.44.8`; chỉ nâng qua PR có analyze/test/build đầy đủ.
- Bật branch protection: CI bắt buộc, review bắt buộc, cấm push thẳng production.
- Thêm secret scanning, dependency review và kiểm tra Android/iOS release build.
- Tách GitHub Environments `staging` và `production`, yêu cầu approval khi deploy.
- Tích hợp crash reporting có lọc PII; tuyệt đối không gửi mật khẩu, token, QR thô
  hoặc response body SAP.
- Thiết lập dashboard: tỷ lệ login lỗi, queue pending/failed, sync latency, HTTP
  error rate và app crash-free sessions.

## P2 — QA trước phát hành

- Test thiết bị thật Android/iOS: camera permission, QR, offline, mất mạng giữa
  transaction, token hết hạn, logout khi SAP offline và app bị kill.
- Kiểm tra dữ liệu trùng với idempotency, clock lệch, retry 401/409/429/5xx.
- Pen-test APK/IPA: secret extraction, cleartext traffic, backup, screenshot/log
  leakage, deep-link/route authorization và tampered QR.
- Load test SAP/gateway theo số thiết bị và tần suất ghi sản lượng thực tế.
- Pilot một tổ sản xuất, có rollback và hướng dẫn hỗ trợ vận hành.

## Thông tin cần cung cấp để triển khai

1. Application ID Android và Bundle ID iOS chính thức.
2. URL gateway/SAP cho dev, staging và production.
3. JSON mẫu của login/profile, đặc biệt `Role`, `Permissions`, `TeamIds`.
4. Đặc tả API master data và API sync/ACK cho assignment, production, recall.
5. Quyết định phân phối: Google Play Internal Testing và TestFlight hay MDM.
6. Android upload keystore; Apple Team ID/certificate/profile/API key.
7. Chính sách lưu offline, thời hạn session, retention audit và yêu cầu PII.

## Tiêu chí Go-live

- Không còn service credential trong binary hoặc source control.
- Không có token/mật khẩu trong URL hay log.
- Dữ liệu pending tồn tại sau khi process/app/device restart.
- Mọi API ghi được backend kiểm tra role, permission, team scope và idempotency.
- Android/iOS production được ký hợp lệ, CI tái lập được và có rollback.
- Pilot đạt các ngưỡng crash, sync success và latency đã thống nhất.
