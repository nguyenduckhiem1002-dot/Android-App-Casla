# Casla Production — trạng thái sẵn sàng production

Tài liệu này phản ánh trạng thái source hiện tại sau các phase hardening. CI xanh là điều kiện cần nhưng **không đồng nghĩa đã được phép go-live**: một số hạng mục cần credential/identity chính thức, thay đổi kiến trúc SAP hoặc kiểm thử ngoài thiết bị thật.

## 1. Những phần đã hoàn thành trong source

### Persistence và offline/sync

- `CaslaDatabase` dùng SQLite persistent, schema version và migration; không còn là in-memory store.
- `SyncQueue` và `AuditLog` được lưu bền vững; queue tồn tại qua app/process restart.
- Luồng ghi dùng verified sync coordinator, phân loại lỗi, retry/terminal state và đối soát kết quả SAP.
- Có integration test cho offline → restart → sync, test migration/persistence/stream, chaos test mạng SAP và performance test database.
- WorkHistory có SQLite cache, namespace theo account/permission/date, stale-while-revalidate và in-flight request deduplication.
- WorkHistory UI chỉ render 50 giao dịch mỗi lượt rồi cho phép tải thêm, giảm chi phí build widget trên PDA.

### Auth, scope và dữ liệu nhạy cảm

- Session refresh/logout có guard chống concurrent refresh làm sống lại session đã logout.
- App fail-closed với permission/team scope thiếu hoặc không hợp lệ; SAP/backend vẫn là security boundary cho mọi write.
- Android manifest tắt backup và cleartext traffic.
- Network logging chỉ bật ở debug; test redaction bảo vệ token/password/header nhạy cảm.
- Field telemetry chỉ dùng enum đóng và số aggregate in-memory; không nhận barcode, WorkerID, token, credential, SAP payload hoặc error text.

### RS38/PDA

- Có native CipherLab scanner bridge, hardware-first scanner và camera/manual fallback.
- Có scan deduplication, phản hồi haptic/trạng thái, lỗi worker persistent/accessibility và touch target phù hợp PDA.
- CI compile Android production flavor cùng native scanner bridge.

### Android release hardening

- Có flavor `dev`, `staging`, `production`.
- Production Application ID và signing input lấy từ secret/env hoặc `key.properties` đã gitignore.
- Production release không fallback sang debug signing.
- `verifyCaslaSigning` fail-closed khi Application ID còn placeholder, thiếu keystore/password/alias hoặc `ENABLE_DEMO_DATA=true`.
- CI kiểm tra độc lập cả signing guard và demo-data guard.
- Xem `android/PRODUCTION_SIGNING.md`.

### iOS build hardening

- CI compile Flutter iOS release không ký và chạy Xcode build validation.
- Có `ios/verify_production_identity.sh` để fail-closed khi Bundle ID vẫn placeholder hoặc thiếu Apple Team ID.
- Xem `ios/PRODUCTION_SIGNING.md`.

### CI hiện tại

CI ghim Flutter `3.44.8` và bắt buộc chạy:

1. `dart format`.
2. `flutter analyze`.
3. toàn bộ `flutter test`.
4. Android `productionDebug` build + native RS38 bridge.
5. Android release signing/identity guard.
6. Android production demo-data guard.
7. iOS release compile không ký.
8. Xcode archive-setting build validation.
9. iOS production identity guard.

Không nâng dependency/toolchain hàng loạt chỉ vì có version mới; mỗi lần nâng phải là PR riêng có full gate tương ứng.

## 2. P0 — Blocker trước production go-live

### P0.1 — Loại shared SAP Basic credential khỏi mobile binary

Đây là blocker kiến trúc quan trọng nhất còn lại.

Client hiện vẫn nhận `SAP_BASIC_AUTH_USER` / `SAP_BASIC_AUTH_PASSWORD` qua compile-time configuration và `SapODataClient` dùng Basic Authorization để gọi SAP. User access token lại được truyền trong RAP contract riêng. Dù secret không nằm trong source control, **shared Basic credential đóng gói trong APK/IPA vẫn có thể bị trích xuất khỏi binary**.

Trước go-live cần:

- Đưa service credential về SAP API Management/BTP/gateway hoặc backend tin cậy; không phân phối shared SAP credential cho mobile.
- Chốt mobile auth contract dùng token ngắn hạn và cơ chế refresh/revoke phù hợp.
- Không đưa access token/password vào query string nếu gateway/backend cho phép chuyển sang header/secure contract.
- Giữ backend authorization cho role, permission, team scope và idempotency ở mọi write API.
- Chỉ đổi client protocol sau khi backend contract đã được thống nhất; không tự thay Basic/Bearer một phía.

### P0.2 — Cung cấp production identity và signing thật

Android còn cần:

- `CASLA_ANDROID_APPLICATION_ID` chính thức.
- upload keystore, store password, key alias và key password trong secret store/GitHub Environment.
- quyết định Play App Signing hoặc MDM/private distribution.

Các guard hiện tại sẽ chặn production release khi các giá trị này chưa có.

iOS còn cần:

- `CASLA_IOS_BUNDLE_ID` chính thức.
- `CASLA_IOS_TEAM_ID`.
- distribution certificate/profile hoặc managed signing setup.
- App Store Connect API credential nếu deploy TestFlight/App Store.

Compile-only CI hiện tại **không phải** signed distribution pipeline.

### P0.3 — Kiểm thử hệ thống thật

Trước go-live phải có:

- smoke test với SAP/gateway production-like environment.
- pilot trên CipherLab RS38 thật, gồm trigger scan liên tục, sleep/resume, mất mạng, app kill/restart và camera fallback.
- test quyền/scope bằng nhiều account thật.
- offline → restart → reconnect → SAP ACK trên thiết bị thật.
- rollback plan và quy trình hỗ trợ vận hành.

## 3. P1 — Security và vận hành nên hoàn tất trước rollout rộng

### CipherLab broadcast trust boundary

Native bridge phải nhận broadcast từ ReaderConfig bên ngoài app; trên Android 13+ receiver hiện cần exported behavior để vendor app có thể gửi scan. Vì vậy vẫn còn trust-boundary risk nếu một app khác có thể spoof broadcast.

Không đổi sang `RECEIVER_NOT_EXPORTED` một cách mù vì có thể làm hỏng RS38. Cần xác minh tài liệu/vendor xem có permission, package restriction hoặc signed broadcast contract hay không. Dù vậy barcode vẫn phải qua parser/scope/backend validation; broadcast không được coi là authorization.

### GitHub/repository controls

Cần kiểm tra/bật bằng quyền admin repository nếu chưa có:

- branch protection/ruleset yêu cầu CI + review trước merge.
- secret scanning/push protection.
- Dependabot/dependency review hoặc giải pháp tương đương.
- CodeQL/SAST phù hợp với Dart/Kotlin/Swift nếu tổ chức sử dụng.
- GitHub Environments `staging`/`production` với approval cho release secrets.

Các setting này không thể được xác nhận chỉ bằng source tree.

### Observability

Telemetry source hiện chỉ là privacy-safe aggregate in-memory, chưa tự gửi ra ngoài. Nếu cần remote observability:

- chỉ export metric allowlist, không cho free-form label.
- không gửi QR/barcode, WorkerID, token, password, SAP payload/body hoặc raw error.
- định nghĩa retention, access control và sampling trước khi bật.

## 4. P2 — QA/release validation

- Pen-test APK/IPA: binary secret extraction, cleartext/TLS, backup, log/screenshot leakage, route authorization và tampered QR.
- Retry/error matrix: 401/403/409/429/5xx, timeout, network flap, token expiry giữa transaction.
- Load test SAP/gateway theo concurrency thiết bị và tần suất ghi thực tế.
- Kiểm thử clock skew, duplicate/idempotency và long-running queue.
- Pilot một tổ trước rollout rộng; theo dõi crash-free rate, sync success, queue age và latency.
- Kiểm thử upgrade/migration từ version đang phát hành sang schema hiện tại.

## 5. Release checklist

### Android

- [ ] Application ID chính thức đã cấu hình.
- [ ] Keystore/alias/password nằm trong secret store, không nằm trong repo.
- [ ] `ENABLE_DEMO_DATA` không được bật.
- [ ] Endpoint SAP/gateway là HTTPS production endpoint.
- [ ] `verifyCaslaSigning` pass trong authorized release environment.
- [ ] Signed AAB/APK được xác minh certificate/package trước phân phối.
- [ ] RS38 physical-device smoke pass.

### iOS

- [ ] Bundle ID chính thức đã cấu hình.
- [ ] Apple Team ID và distribution signing material đã cấu hình.
- [ ] `ios/verify_production_identity.sh` pass trong authorized release environment.
- [ ] Signed archive/IPA được export bằng production pipeline, không dùng `--no-codesign`.
- [ ] TestFlight/MDM smoke pass.

### Backend/SAP

- [ ] Shared Basic service credential không còn nằm trong mobile binary.
- [ ] Role/permission/team scope được kiểm tra server-side cho mọi write.
- [ ] Idempotency được SAP/backend enforce.
- [ ] Token/session revoke và expiry đã test.
- [ ] Production monitoring và rollback procedure sẵn sàng.

## 6. Tiêu chí Go-live

Go-live chỉ đạt khi đồng thời:

- CI source hiện tại xanh trên commit phát hành.
- Không có shared service credential có thể trích xuất từ mobile binary.
- Android/iOS có identity và signing chính thức.
- Demo data bị tắt và endpoint production được xác nhận.
- Pending transaction sống qua restart và sync/ACK đúng với SAP.
- Backend enforce authorization/scope/idempotency.
- Pilot RS38 + security/load/rollback validation đạt ngưỡng đã thống nhất.

Nếu P0.1 chưa giải quyết, trạng thái đúng là **codebase hardened / pilot-capable**, chưa phải production go-live ready.
