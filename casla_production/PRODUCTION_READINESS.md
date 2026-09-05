# Casla Production — trạng thái sẵn sàng production

Tài liệu này phản ánh trạng thái source hiện tại sau các phase hardening. CI xanh là điều kiện cần nhưng **không đồng nghĩa đã được phép go-live**: một số hạng mục cần credential/identity chính thức, gateway SAP production hoặc kiểm thử ngoài thiết bị thật.

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

### SAP transport security

- `SapODataClient` có hai transport mode rõ ràng: `basic` và `gateway`.
- `basic` chỉ dành cho direct-SAP dev/staging và vẫn yêu cầu credential hợp lệ.
- `gateway` không tạo/gửi shared Basic `Authorization` header, kể cả lúc fetch CSRF token.
- `gateway` fail-closed nếu mobile vẫn được cấu hình `SAP_BASIC_AUTH_USER` hoặc `SAP_BASIC_AUTH_PASSWORD`.
- Release runtime yêu cầu `SAP_TRANSPORT_AUTH_MODE=gateway`.
- Android release guard và cross-platform `tool/verify_transport_security.sh` cấm production chứa shared Basic credential.
- Existing RAP user access-token payload contract được giữ nguyên; source không tự ý đổi sang HTTP Bearer khi backend chưa đổi contract.

### RS38/PDA và scanner trust boundary

- Có native CipherLab scanner bridge, hardware-first scanner và camera/manual fallback.
- Native receiver chỉ tồn tại khi activity đang `started` và Flutter có active scanner listener.
- Trên Android 14/API 34+, broadcast scanner phải có initial sender package đúng `com.cipherlab.clbarcodeservice`; sender null/lạ bị drop.
- Chỉ nhận `Decoder_Data` đã qua ReaderConfig processing; không fallback sang `Original_Decoder_Data`.
- Native payload được type-check và giới hạn 4096 ký tự/8192 byte; embedded NUL bị reject; symbology cũng được giới hạn.
- Dart platform event parser fail-closed với source lạ, kiểu dữ liệu sai, timestamp/symbology sai và payload quá dài.
- Worker QR parser có giới hạn input độc lập, chỉ trích xuất mã nhân viên; master data/scope/authorization không lấy từ QR.
- Có native JVM test cho sender/payload policy và Flutter tests cho event/QR validation.
- Có scan deduplication, phản hồi haptic/trạng thái, lỗi worker persistent/accessibility và touch target phù hợp PDA.
- Xem `android/SCANNER_SECURITY.md` cho residual risk và test matrix thiết bị thật.

### Android release hardening

- Có flavor `dev`, `staging`, `production`.
- Production Application ID và signing input lấy từ secret/env hoặc `key.properties` đã gitignore.
- Production release không fallback sang debug signing.
- `verifyCaslaSigning` fail-closed khi Application ID còn placeholder, thiếu keystore/password/alias, `ENABLE_DEMO_DATA=true`, transport khác `gateway`, hoặc Basic credential bị embed.
- CI kiểm tra độc lập signing, demo-data và transport-security guard.
- Xem `android/PRODUCTION_SIGNING.md`.

### iOS build hardening

- CI compile Flutter iOS release không ký và chạy Xcode build validation.
- `ios/verify_production_identity.sh` fail-closed khi Bundle ID vẫn placeholder hoặc thiếu Apple Team ID, sau đó chạy production transport-security guard.
- Xem `ios/PRODUCTION_SIGNING.md`.

### Supply-chain security

- Dependabot theo dõi `pub`, Gradle và GitHub Actions hàng tuần.
- Version-update automation bỏ qua semver-major; minor/patch được gom theo ecosystem. Major upgrade phải là PR chủ động có full gate.
- Dependency Review chạy trên pull request và fail khi dependency mới đưa vào lỗ hổng `high`/`critical`.
- CodeQL Action v4 dùng manual production-like build để scan Java/Kotlin và Swift.
- Dart **không được CodeQL hỗ trợ**, nên không coi CodeQL là SAST coverage cho Flutter/Dart; Dart vẫn dựa vào `flutter analyze`, tests, Dependabot/dependency review và focused security tests.
- Workflow checkout đã chuyển sang `actions/checkout@v6`.
- Xem `SUPPLY_CHAIN_SECURITY.md` cho scope, limitations và repository-side controls còn phải bật.

### CI hiện tại

CI ghim Flutter `3.44.8` và bắt buộc chạy:

1. `dart format`.
2. `flutter analyze`.
3. toàn bộ `flutter test`.
4. Android `productionDebug` build + native RS38 bridge.
5. native scanner trust-policy JVM tests.
6. Android release signing/identity guard.
7. Android production demo-data guard.
8. Android gateway-only/no-Basic transport guard.
9. iOS release compile không ký.
10. iOS AOT sentinel scan chứng minh Basic credential define không nằm trong release binary.
11. Xcode archive-setting build validation.
12. iOS production identity + transport guard.

Security workflows bổ sung:

- `Dependency Review` trên pull request.
- `CodeQL Java/Kotlin` và `CodeQL Swift` trên branch/PR và lịch hàng tuần.

Không nâng dependency/toolchain hàng loạt chỉ vì có version mới; mỗi lần nâng major phải là PR riêng có full gate tương ứng.

## 2. P0 — Blocker trước production go-live

### P0.1 — Triển khai trusted SAP gateway cho production

**Mobile half đã được harden trong source:** production release giờ bắt buộc `gateway` mode và cấm shared SAP Basic credential trong APK/IPA.

Phần còn lại là hạ tầng/backend, không thể hoàn thành chỉ bằng source mobile:

- Deploy SAP API Management/BTP/gateway hoặc backend tin cậy làm production `SAP_BASE_URL`.
- Gateway phải giữ upstream SAP service credential ở server-side secret store; không trả credential đó về mobile.
- Xác minh gateway proxy đúng hai service path hiện tại và CSRF/session-cookie behavior.
- Giữ backend authorization cho role, permission, team scope và idempotency ở mọi write API.
- Chốt bước tiếp theo cho user-token contract (header hay RAP payload) ở backend trước khi đổi mobile; hiện client cố ý giữ contract RAP đang chạy.
- Nếu backend cho phép, loại token/password khỏi query string trong một thay đổi contract riêng có integration tests.

**Cho tới khi gateway production được triển khai và smoke-test, go-live vẫn bị chặn**, nhưng production binary phía mobile không còn được phép chứa shared Basic credential.

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

- smoke test với gateway/SAP production-like environment.
- pilot trên CipherLab RS38 thật, gồm trigger scan liên tục, sleep/resume, mất mạng, app kill/restart và camera fallback.
- test quyền/scope bằng nhiều account thật.
- offline → restart → reconnect → SAP ACK trên thiết bị thật.
- rollback plan và quy trình hỗ trợ vận hành.

## 3. P1 — Security và vận hành nên hoàn tất trước rollout rộng

### CipherLab broadcast — residual risk trên Android 13 trở xuống

Source đã harden được phần có thể làm chắc chắn mà không phá vendor integration: Android 14+ xác minh initial sender là Reader Service, chỉ nhận processed `Decoder_Data`, giới hạn payload, validate lại ở Dart và không coi scan là authorization.

Điểm chưa thể đóng hoàn toàn bằng source hiện tại là **Android 13/API 33 trở xuống**. `BroadcastReceiver.getSentFromPackage()` chỉ có từ API 34; với implicit external broadcast hiện tại, app không có một sender identity tương đương để chứng minh cryptographically ai đã phát broadcast. Do đó các thiết bị này vẫn là `legacy sender-unverified`.

Trước rollout rộng cần xác minh trên firmware RS38 thực tế xem CipherLab có một trong các contract mạnh hơn hay không:

- sender/signature permission cho `PASS_DATA_2_APP`;
- explicit/package-targeted output có thể authenticate;
- Reader SDK/service API có trust boundary mạnh hơn;
- hoặc OS/firmware nâng lên Android 14+ và xác nhận package sender thực tế.

Không đổi sang `RECEIVER_NOT_EXPORTED` một cách mù vì Reader Service nằm ngoài APK và như vậy có thể làm hỏng hardware scanning. Xem `android/SCANNER_SECURITY.md`.

### GitHub/repository controls — source đã có check, admin enforcement còn thiếu

Source đã có Dependabot config, Dependency Review và CodeQL native workflow. Tuy nhiên source **không thể tự biến các check này thành mandatory merge gate**.

Repository-side cần xác minh/bật:

- ruleset/branch protection cho `master`, yêu cầu PR + review và không cho direct/force push;
- require `Dart analyze and tests`, `Android / PDA build`, `iOS / Xcode build`;
- require `Dependency Review`, `CodeQL Java/Kotlin`, `CodeQL Swift` khi applicable;
- dependency graph/Dependabot alerts;
- secret scanning/push protection nếu plan/repository hỗ trợ;
- GitHub Environments `staging`/`production` với approval cho release secrets.

Khi phase này được chuẩn bị, repository ruleset API trả về danh sách rỗng; legacy branch-protection endpoint không đọc được qua GitHub integration hiện tại, nên **không được suy diễn rằng `master` đang được bảo vệ chỉ vì CI tồn tại**. Xem `SUPPLY_CHAIN_SECURITY.md`.

### Observability

Telemetry source hiện chỉ là privacy-safe aggregate in-memory, chưa tự gửi ra ngoài. Nếu cần remote observability:

- chỉ export metric allowlist, không cho free-form label.
- không gửi QR/barcode, WorkerID, token, password, SAP payload/body hoặc raw error.
- định nghĩa retention, access control và sampling trước khi bật.

## 4. P2 — QA/release validation

- Pen-test APK/IPA: binary secret extraction, cleartext/TLS, backup, log/screenshot leakage, route authorization và tampered QR.
- Retry/error matrix: 401/403/409/429/5xx, timeout, network flap, token expiry giữa transaction.
- Load test gateway/SAP theo concurrency thiết bị và tần suất ghi thực tế.
- Kiểm thử clock skew, duplicate/idempotency và long-running queue.
- Pilot một tổ trước rollout rộng; theo dõi crash-free rate, sync success, queue age và latency.
- Kiểm thử upgrade/migration từ version đang phát hành sang schema hiện tại.

## 5. Release checklist

### Android

- [ ] Application ID chính thức đã cấu hình.
- [ ] Keystore/alias/password nằm trong secret store, không nằm trong repo.
- [ ] `ENABLE_DEMO_DATA` không được bật.
- [ ] `SAP_TRANSPORT_AUTH_MODE=gateway`.
- [ ] Không truyền `SAP_BASIC_AUTH_USER`/`SAP_BASIC_AUTH_PASSWORD` vào production build.
- [ ] `SAP_BASE_URL` là HTTPS gateway production endpoint.
- [ ] `verifyCaslaSigning` pass trong authorized release environment.
- [ ] Signed AAB/APK được xác minh certificate/package trước phân phối.
- [ ] RS38 physical-device smoke + scanner trust test matrix trong `android/SCANNER_SECURITY.md` đã pass.

### iOS

- [ ] Bundle ID chính thức đã cấu hình.
- [ ] Apple Team ID và distribution signing material đã cấu hình.
- [ ] `SAP_TRANSPORT_AUTH_MODE=gateway`, không có Basic credential trong build.
- [ ] `ios/verify_production_identity.sh` pass trong authorized release environment.
- [ ] Signed archive/IPA được export bằng production pipeline, không dùng `--no-codesign`.
- [ ] TestFlight/MDM smoke pass.

### Repository/release controls

- [ ] `master` được bảo vệ bằng ruleset/branch protection và required review.
- [ ] CI + Dependency Review + native CodeQL checks được require trước merge khi applicable.
- [ ] Dependabot alerts/dependency graph được bật và alert queue không có unresolved blocker.
- [ ] Secret scanning/push protection được bật nếu GitHub plan hỗ trợ.
- [ ] Production release secrets nằm trong protected environment, không phải repository variables/source.

### Backend/SAP

- [ ] Trusted gateway đã deploy và giữ upstream SAP service credential server-side.
- [ ] Mobile production endpoint đi qua gateway; shared Basic service credential không nằm trong binary.
- [ ] Role/permission/team scope được kiểm tra server-side cho mọi write.
- [ ] Idempotency được SAP/backend enforce.
- [ ] Token/session revoke và expiry đã test.
- [ ] Production monitoring và rollback procedure sẵn sàng.

## 6. Tiêu chí Go-live

Go-live chỉ đạt khi đồng thời:

- CI source hiện tại xanh trên commit phát hành.
- Production mobile build dùng gateway mode và không chứa shared service credential.
- Gateway production đã deploy, bảo vệ upstream SAP credential và qua smoke/load/security test.
- Android/iOS có identity và signing chính thức.
- Demo data bị tắt và endpoint production được xác nhận.
- Pending transaction sống qua restart và sync/ACK đúng với SAP.
- Backend enforce authorization/scope/idempotency.
- Repository merge/release controls được enforce, không chỉ tồn tại dưới dạng workflow file.
- Pilot RS38 + security/load/rollback validation đạt ngưỡng đã thống nhất.

Khi gateway/signing/device-pilot hoặc repository enforcement chưa hoàn tất, trạng thái đúng là **codebase hardened / production-contract-ready**, chưa phải production go-live ready.
