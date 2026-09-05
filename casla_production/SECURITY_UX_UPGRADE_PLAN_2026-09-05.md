# Casla Production — audit bảo mật và kế hoạch nâng cấp định kỳ

Ngày: 05/09/2026. Snapshot: `bccf5904eaf2975dfd721e9c3a68a0165f27ebf5`, nhánh `master`.

## 1. Kết luận và phạm vi

Nền tảng đã có nhiều cải thiện đúng hướng: SQLite bền vững, transaction cho entity/queue/audit, gateway-only ở release, Android tắt backup/cleartext, scanner validation, cache WorkHistory có namespace và gom request trùng. Tuy nhiên, chưa nên coi là sẵn sàng triển khai rộng: còn lỗi vòng đời phiên, quyền truy cập cache, log nhạy cảm, tính toàn vẹn số lượng và thiếu bootstrap master data cho cài mới.

Ưu tiên đề xuất: **bảo mật phiên/cache + dữ liệu đúng → cache phản ánh đúng lên UI → tối ưu truy vấn/render → hoàn thiện thao tác PDA → pilot và release có kiểm soát**. Giữ Flutter/Riverpod/SQLite hiện có; không nâng major hoặc đổi framework để đạt mục tiêu này.

Đã thực hiện:

- `git fetch origin --no-recurse-submodules` và `git pull --ff-only --no-recurse-submodules origin master`: `Already up to date`; HEAD và origin/master trùng nhau.
- Giữ nguyên submodule ABAP đang sửa và các thư mục untracked có sẵn. Không stash/reset/commit/push, không sửa app hoặc backend.
- `flutter analyze --no-pub`: không có issue. `flutter test --no-pub --reporter expanded`: **171/171 pass** trên Flutter 3.44.8/Dart 3.12.2.
- Năm probe cục bộ bằng dữ liệu tổng hợp xác nhận hành vi hiện tại: redaction thiếu, đọc cache sau auth rejection, vượt trần khi ghi đồng thời, Back đóng mandatory password dialog, DB cài mới không có master data khi demo=false. Các probe tạm đã được gỡ; khi sửa phải thêm regression test với kỳ vọng an toàn ngược lại.
- OSV querybatch: **83 package hosted/Pub** trong lockfile, 83 kết quả, **0 advisory được trả về**, không có trang tiếp theo. Không tương đương chứng nhận không có lỗ hổng; chưa quét đầy đủ dependency native/Flutter engine/Git history.
- GitHub REST xác nhận `master.protected=false`, required-status-check enforcement=`off` trên SHA trên. Đây là trạng thái đã kiểm tra, không chỉ suy ra từ workflow.

Giới hạn: audit source mobile và workflow; không pentest SAP/gateway thật, không audit lại ABAP đang thay đổi, không đọc secret thật, không kiểm tra signed APK/IPA, không chạy profile/visual QA trên RS38. Benchmark SQLite máy phát triển không chứng minh FPS trên PDA. Các vấn đề server-side dưới đây là yêu cầu xác minh, không phải kết luận đã khai thác SAP.

## 2. Findings bảo mật và tính toàn vẹn

Severity thể hiện tác động theo điều kiện nêu dưới đây; P0/P1 là thứ tự xử lý, không phải điểm CVSS.

### SEC-01 — High, P0: cache vẫn hiển thị sau khi biết phiên không hợp lệ

**Bằng chứng:** `lib/data/repositories/repositories_impl.dart:767,799` trả cache và nuốt mọi lỗi SWR; `lib/features/worker/screens/w01_history_screen.dart:65` bắt mọi lỗi force refresh rồi gọi lại đường cache. Probe nạp cache → remote ném `TOKEN_INVALID_OR_EXPIRED` → đọc thường vẫn nhận bản lưu trước đó.

**Tác động:** người đang dùng thiết bị vẫn đọc được lịch sử nhạy cảm dù app vừa biết token bị từ chối. Khác với tình huống mất mạng chưa thể biết quyền đã bị thu hồi.

**Sửa:** phân biệt offline/transient với auth/forbidden; khi biết bị thu hồi phải khóa dữ liệu protected, invalidation cache/projection và yêu cầu đăng nhập lại. Giữ nguyên outbox chưa ACK, không xóa giao dịch để giải quyết logout. Chốt thời hạn cho phép đọc offline khi chưa có tín hiệu revoke; hiển thị độ cũ dữ liệu rõ ràng.

### SEC-02 — High có điều kiện, P0: namespace cache thiếu phạm vi tổ và session generation

**Bằng chứng:** `lib/core/auth/session_manager.dart:75` chỉ ghép user ID + hai permission history; không có team/work context hoặc scope revision. `repositories_impl.dart:836` ghi kết quả sau network await mà không xác nhận session còn là phiên khởi phát. Cache hit cũng không kiểm tra lại session sau SQLite await.

**Kịch bản:** cùng user vẫn có `PP_HIST_TEAM`, nhưng bị chuyển từ tổ A sang B; key không đổi nên snapshot A được tái sử dụng, kể cả stale. Request A đang chờ refresh có thể retry dưới phiên B trong gateway, rồi lưu response vào key đã chụp của A. Kịch bản race xuyên phiên này mới xác minh bằng code, chưa có end-to-end exploit.

**Sửa:** key có tenant/environment + subject + authorization-scope fingerprint/revision + query/date; generation chống response cũ được publish/ghi. Scope fingerprint phải bao phủ phạm vi thực tế backend dùng; nếu login chưa trả đủ thì cần backend scope revision, không đoán từ QR. Refresh quyền phải cập nhật session và notify đúng, không chỉ copy token.

### SEC-03 — High có điều kiện, P0: refresh cũ có thể ghi đè phiên mới

**Bằng chứng:** `lib/core/auth/session_manager.dart:145` chụp `current`, await refresh, chỉ kiểm tra `_currentSession != null` ở dòng 157 rồi ghi lại `current.copyWithTokens`. Sau A logout và B login, điều kiện vẫn đúng. Refresh không có single-flight dù refresh token là single-use. `logout():110` chờ mạng trước khi thu hồi quyền local.

**Tác động:** race có thể phục hồi identity/token A trong khi UI thuộc B; requests cũ hoặc logout cũ cũng có thể tác động phiên mới. Chưa tái hiện trên gateway thật.

**Sửa:** session generation/identity guard cho login, refresh, logout và mọi completion; refresh single-flight theo generation; local logout tức thời, remote revoke best-effort bằng token đã chụp; cancel/ignore request cũ, reset cookie/CSRF của cả hai client và dừng sync theo session. Inject auth/clock/network để kiểm thử bằng Completer, không cần secret.

### SEC-04 — Medium, P0 quick fix: log debug bỏ sót secret thật của contract SAP

**Bằng chứng:** `lib/data/sap/sap_odata_client.dart:101,120` bật log body/header ở debug nhưng redactor chỉ có `access_token`, `refresh_token` và một số dạng password. Probe xác nhận còn nguyên sentinel trong `AccessToken`, `RefreshToken`, JSON `{"Password":"..."}`, `set-cookie` và `x-csrf-token`. Login response dùng camel-case; Dio stringify response thành JSON.

**Tác động:** lộ secret nếu debug/staging dùng account thật và người khác đọc được log. Release không gắn LogInterceptor: không gán nhầm lỗi này thành release token leak đã chứng minh.

**Sửa:** không log auth request/response body; structured redaction đệ quy và header allowlist cho chẩn đoán cần thiết, bao phủ JSON/map/camelCase/cookie/bearer/CSRF. Rà thêm `debugPrint` và raw error/clipboard. Nếu trước đây đã thu log thật, xử lý lưu trữ log và rotate/revoke theo phạm vi, không mặc định rằng xóa code là đủ.

### SEC-05 — Medium, P0: bypass bước đổi mật khẩu bắt buộc ở app

**Bằng chứng:** `lib/features/account/widgets/change_password_dialog.dart:18,192` chỉ khóa barrier, không khóa pop; router không gate `passwordChangeRequired`. Probe `handlePopRoute()` đóng dialog. Shell chỉ hỏi một lần và history bắt đầu tải trước dialog.

**Sửa:** trạng thái auth riêng `passwordChangeRequired`; router chỉ cho đổi mật khẩu/logout, không mount màn protected. Back đưa tới logout/cancel-login an toàn; không nhốt người dùng trong dialog. Backend phải giới hạn token provisional tương ứng. Chưa kết luận backend cho phép write khi chưa đổi mật khẩu.

### SEC-06 — Medium, P0: queue và xác minh thiếu phạm vi phiên local

**Bằng chứng:** `lib/core/database/casla_database.dart:1233,1255` lấy toàn queue hoặc theo worker, không có subject/team policy; S12 dùng trực tiếp feed ở dòng 248. Coordinator không nhận session/scope, và mỗi push đọc token hiện thời. Engine khởi động từ AppState ngay cả khi chưa đăng nhập.

**Tác động:** trên PDA dùng chung, supervisor khác tổ có thể thấy summary/lỗi giao dịch cũ và bắt đầu xác minh chuỗi ngoài phạm vi local; các item trong một batch có thể chạy qua nhiều phiên nếu người dùng đổi account. SAP vẫn có thể từ chối, nên đây không phải bằng chứng bypass authorization server.

**Sửa:** query và execute cùng một policy theo tenant/scope/actor, session generation cố định cho batch; review rõ ai được tiếp quản outbox của người trước. Item không rõ ownership phải được giữ và cách ly, không xóa. Kiểm tra quyền lại trước push; admin recovery có audit.

### INT-01 — High về dữ liệu, P0: validation nằm ngoài transaction

**Bằng chứng:** `repositories_impl.dart:435,443,504` đọc status/tổng trước commit; `casla_database.dart:970` transaction chỉ insert/update, không kiểm tra lại ceiling. Recall có cấu trúc tương tự tại repo:590 và DB:1158.

**Đã tái hiện:** assignment giao 650, hoàn thành 436, còn 214; hai `recordProduction(quantity:200)` chạy đồng thời đều ghi thành công local, tổng thành **836**. Đây là sai lệch local đã xác nhận; backend có thể reject nhưng UI/outbox vẫn sai. Idempotency key khác nhau không ngăn lỗi này.

**Sửa:** đọc trạng thái + tổng + validate + insert entity/queue/audit trong cùng transaction, notify sau commit. Single-flight thao tác ngay trước khi mở dialog; finite-number/precision validation. Test hai confirm, confirm-vs-recall, hai recall, closed assignment và rejected transaction projection.

### OPS-01 — High, P0 release gate: master chưa protected

GitHub REST trả `protected=false`, enforcement `off` ngày audit. CI/CodeQL/Dependency Review đã có nhưng chưa là gate bắt buộc. Admin cần require PR/review/checks, chặn direct/force push và bảo vệ production environment. Không sửa cấu hình GitHub trong lượt audit này.

### Rủi ro tồn dư cần kiểm chứng, không đánh đồng với exploit đã có

- Android <=13: native policy chấp nhận sender chưa xác minh; đã được ghi trong `android/SCANNER_SECURITY.md`. Chốt vendor permission/SDK, firmware và MDM; scan không được trở thành authorization.
- SQLite chưa có mã hóa riêng ở tầng app. Sandbox/OS protection vẫn tồn tại; cần threat model PDA mất máy/rooted, iOS backup/data protection và app-switcher screenshot. Chỉ thêm encryption khi có kế hoạch quản lý key/migration/recovery, không hy sinh outbox.
- Gateway production, upstream service credential, quyền ở plain entity GET (`getUserDetail`), CSRF/session isolation và server idempotency cần test bằng nhiều account. Không mở generic proxy tới toàn bộ SAP entity chỉ vì mobile đã bỏ Basic secret.
- OSV chỉ phủ package Pub đã khóa; cần SBOM/native transitive, secret scan toàn history, kiểm tra trạng thái Dependabot/CodeQL/secret scanning thực tế.

## 3. Khoảng trống chức năng, cache và độ mượt

| ID | Bằng chứng hiện tại | Tác động / đề xuất |
|---|---|---|
| UX-00, P0 | `casla_database.dart:96,549,573,738,744`: demo=false không seed; history chỉ tạo tên worker với `to_ids=[]`; không tìm thấy đường nạp orders/teams từ network. S07 picker đọc local. | Cài mới không thể hoàn tất phân công. Thêm master-data bootstrap có quyền, operation keys, worker-team membership và trạng thái sẵn sàng; không bật demo để chữa. Cần chốt contract backend. |
| UX-01, P1 | Repo:767 trả stale, refresh unawaited; DB replace cache không emit; W01:367 dùng FutureBuilder. S06:113/S06b:70 pull-refresh không force. | DB đã mới nhưng màn vẫn cũ; kéo làm mới có thể vẫn nhận cache. Dùng snapshot reactive chung có `fetchedAt`, source, stale, refreshing, error; force refresh phải đi network/gom in-flight và publish khi xong. |
| UX-02, P1 | S06:101 biến lỗi thành report rỗng; S06:498 ưu tiên hoàn toàn SAP summary; S06b:260–318 ưu tiên SAP hoặc fallback extra. | Lỗi trông như không có dữ liệu; thay đổi offline không phản ánh KPI khi đã có SAP summary; extra có thể hiện số ngày cũ. Tách server-confirmed và local-pending, đối soát bằng stable transaction ID, không cộng hai nguồn mù. |
| UX-03, P1 | S12:281,346 và W01:643 từng dùng nested shrinkWrap ListView. S12 query toàn bộ; W01 gọi RAP static action OData V4 `getWorkHistory` với deep result `_Entries`, nên action hiện vẫn trả toàn bộ report. | S12 đã chuyển sang keyset pagination theo `(created_at_utc, id)`, aggregate COUNT riêng và page tối đa 50. W01 đã chuyển phần dựng danh sách sang `CustomScrollView`/`SliverList`; còn cần mở rộng contract OData V4 action hiện có với cursor/page size (hoặc tách entity collection query) để backend giới hạn dữ liệu trước khi map deep result. |
| UX-04, P1 | S06:420, S06b:177/184, S08:258/293, S09:160, S12:248 tạo stream trong build. Repo:345 tải toàn employees/orders/tổng production/recall kể cả khi chỉ xem một assignment. | Resubscribe/query lại khi gõ/chuyển tab/setState. Stream/provider identity ổn định; selector nhỏ; SQL lọc theo scope/date/IDs trước map; group dữ liệu một lần thay vì lặp `.where` từng worker. |
| UX-05, P1 | Cache key repo:987 có ngày anchor; schema index theo subject nhưng không có prune/eviction; cache read gồm ba query riêng. | Đã thêm snapshot read trong transaction, retention theo tuổi/count và bounded byte pruning xấp xỉ 25MB; chỉ cache bị prune, outbox không bị ảnh hưởng. Cần đo lại cap trên dữ liệu thiết bị thật. |
| UX-06, P1 | Shell:80 eager IndexedStack trừ scanner; DB:1539 query mỗi tick; gateway:235 fetch metadata trước mọi POST bằng Dio mới. | Tab ẩn vẫn giữ subscription/build; sync burst khuếch đại query; thêm RTT mỗi item. Lazy mount + bounded keepalive; coalesce invalidation; cache CSRF/session có single-flight và retry chỉ khi xác định CSRF rejection an toàn. |
| UX-07, P1 | `CaslaColors.muted=#8A8F9B` trên trắng đạt **3,24:1**, trên background **3,00:1**; W01:729/777 dùng cho chữ 10.5/11. | Chữ nhỏ khó đọc. Semantic text tokens >=4.5:1; Android tap >=48dp, CTA thao tác PDA 52–56dp thử trên máy/găng tay; test font scale và landscape. Không coi phép tính contrast là visual QA đã xong. |
| UX-08, P2 | W01:594 dùng `workers.first` dù scope có thể team; lượng hiển thị `toStringAsFixed(0)` nhiều nơi; fonts Manrope/Inter chưa khai báo asset hoạt động. | W01 đã cộng KPI trên toàn bộ worker trong scope và các màn chính dùng formatter số theo UOM, giữ tối đa 3 chữ số thập phân. Typography/font và visual QA trên thiết bị vẫn còn. |
| UX-09, P1/P2 | S07/08 chỉ khóa submit sau dialog; login:73 clear controller trước mounted check trong finally; S12 FAILED chủ yếu xem/copy chẩn đoán. | Chặn reentrancy từ đầu; xử lý lifecycle an toàn; lỗi có CTA phù hợp. Không retry mù business rejection; cần edit/supersede/admin workflow có audit và giữ original/idempotency contract. |

## 4. Kiến trúc đích: cải thiện các module hiện có

`codebase-design` định hướng tập trung logic tại Interface nhỏ thay vì buộc từng màn hiểu TTL, quyền, retry và dedup. Không tạo thêm tầng chỉ để chuyển tiếp lời gọi.

1. **Session module:** login/refresh/logout/provisional-session, generation và scope snapshot. Network/cache/sync dùng cùng phiên; completion cũ bị bỏ. Inject dependencies cho test race.
2. **WorkHistory module:** mở rộng repo hiện có thành `watchHistory(query)` và `refreshHistory(query)`; một snapshot chứa dữ liệu + freshness + trạng thái lỗi. Repository chịu trách nhiệm cache và request coalescing; SQLite/network là các Adapter đã tồn tại.
3. **Mutation module:** transaction chịu toàn bộ invariant số lượng; outbox ownership, per-assignment serialization và SAP receipt reconciliation tập trung. UI chỉ nhận receipt/snapshot rõ nghĩa.
4. **Screen state:** Riverpod family/select theo query có identity ổn định; cache state màn gồm ngày, tổ, tìm kiếm, vị trí cuộn. Reset theo account/scope generation. Không lưu password vào provider persist/cache/draft.

### Chính sách cache đề xuất để pilot

| Dữ liệu | Freshness / invalidation | Giới hạn và bảo vệ |
|---|---|---|
| Lịch sử/KPI | Giữ TTL hiện tại 2 phút làm baseline; trả cache hợp lệ ngay, tự publish kết quả refresh; invalidate sau ACK, đổi ngày/tổ, resume khi stale. | Namespace đầy đủ như SEC-02; explicit auth rejection không fallback. Dự kiến tối đa 20 query windows hoặc 25MB cache/report trên thiết bị, prune LRU; điều chỉnh theo pilot. |
| Master data | Bootstrap đầu phiên và revalidate theo backend revision; chu kỳ khởi điểm 15 phút cho metadata, không coi TTL là bằng chứng quyền. | Scope/tombstone/version từ SAP; thiếu/unknown scope phải fail-closed và có hướng xử lý. |
| UI state/draft | Giữ filter/scroll khi quay lại; draft chỉ dữ liệu không nhạy cảm, reset/revalidate khi đổi user hoặc scope. | Keepalive tab đã truy cập, không dựng hết ngay; tắt ticker/poll của tab ẩn nếu không cần. |
| Outbox/audit | Không áp dụng TTL cache; pending/needsVerification/failed sống qua restart. | Không eviction hoặc xóa khi logout. Prune lịch sử ACK chỉ sau chính sách lưu trữ/audit được duyệt. |

Không dùng `keepAlive` toàn cục hoặc tăng cacheExtent vô hạn. Không retry POST không phân biệt lỗi; giữ cùng idempotency key để đối soát, xác minh lại khi cần worker password.

## 5. Plan triển khai theo PR nhỏ

Ước lượng sơ bộ cho một dev Flutter tập trung, có QA/backend phối hợp; khoảng 4–6 tuần, không bao gồm thời gian chờ hạ tầng/phê duyệt. Mỗi PR có test và rollback riêng. Không tự tạo issue/PR trong lượt này.

| Đợt / PR | Nội dung | Chủ trì / phụ thuộc | Gate nghiệm thu |
|---|---|---|---|
| 0 — 1 ngày | Chốt threat model PDA dùng chung, retention offline, baseline profile, scope ownership; admin bảo vệ master. | Tech lead + Security/DevOps | Scope/owner được duyệt; required checks có enforcement; ghi baseline trên RS38. |
| A1 — 1–2 ngày | SEC-04 logging + regression matrix JSON/map/header. | Flutter | Sentinel không còn ở log; release vẫn không có network body logging. |
| A2 — 2–3 ngày | SEC-03/05 session generation, single-flight refresh, local-first logout, provisional auth route. | Flutter; test SAP token contract | Refresh A không thể thay B; 10 request expiry chỉ một refresh; Back không vào màn protected; logout offline khóa UI tức thời. |
| A3 — 2–3 ngày | SEC-01/02/06 scope-aware cache/queue, auth-error invalidation, batch session guard. | Flutter + backend scope contract | Team A→B không thấy A; revoke không fallback cache; đổi account giữa batch dừng đúng; outbox không mất. |
| A4 — 2–3 ngày | INT-01 validation trong DB transaction, reentrancy, rejected/local projection semantics. | Flutter + SAP idempotency tests | Parallel confirm/recall không vượt trần; rollback không có nửa entity; ACK/crash/replay không trùng. |
| A5 — 3–5 ngày sau chốt contract | UX-00 master bootstrap, master-data readiness/error/retry screen state. | Backend + Flutter | Cài mới demo=false → login → tải master → scan/chọn worker/order → write → restart/reconcile thành công; không nới scope khi thiếu dữ liệu. |
| B1 — 3–4 ngày | UX-01/02 reactive history, refresh thật, stale/offline banner và unified totals. | Flutter; sau A2/A3 | Data mới hiện tự động; response query cũ không ghi đè query mới; local pending visible nhưng không cộng trùng ACK. |
| B2 — 3–4 ngày | UX-03/04/05 scoped SQL, keyset pagination, atomic cache read, bounded eviction, ổn định subscriptions. | Flutter; sau B1 | S12 không dựng toàn queue; page/cursor và COUNT giữ ổn định; cache có age/count/byte bound; migration giữ nguyên outbox. W01 report pagination tiếp tục ở đợt kế. |
| B3 — 1–2 ngày | UX-06 lazy tabs, scoped invalidation, CSRF/session reuse có guard. | Flutter + gateway staging | Không polling/request thừa ở tab ẩn; CSRF expiry/race không làm nhân đôi lệnh; đo RTT trước/sau. |
| C — 3–4 ngày | UX-07/08/09 typography/contrast, touch targets, keyboard/safe area, số/UOM, inline errors, CTA recovery, state restoration. | Flutter + UX/QA | 320/360/375 logical width, landscape, text scale 1.0/1.3/2.0, TalkBack, reduced motion; không mất input/scroll hoặc thông tin quantity. |
| D — 3–5 ngày | Signed staging, device/load/security matrix, pilot một tổ rồi mở rộng. | QA + DevOps + SAP owner | Go-live gates trong PRODUCTION_READINESS đạt; migration, revoke, scanner, rollback và support runbook đã thử. |

A1/A4 có thể làm độc lập với việc thay đổi backend vì chính sách `WorkerPassword` đã được xác nhận là bắt buộc. B1/B2 chỉ rollout sau A2/A3 để không tăng tốc hiển thị dữ liệu sai quyền. App phải giữ password trong memory cho đúng thao tác foreground, không persist/cache/log và không cho background retry tự động khi thiếu xác minh.

## 6. Ngưỡng đo lường và rollout

Các số sau là **mục tiêu pilot**, chưa phải kết quả đạt được. Đo trên RS38 thấp nhất được hỗ trợ, profile mode, dữ liệu 1k/5k/10k, ít nhất 30 lượt mỗi scenario sau warm-up; báo riêng cold/warm, online/offline, UI/raster.

- Tap feedback p95 <=100ms; warm tab switch p95 <=150ms; cached first content p95 <=200ms.
- Với màn 60Hz: UI và raster p95 mỗi phần <16,7ms, mục tiêu headroom <8ms; janky frames <1% trong kịch bản scroll chuẩn. Không suy ra từ test SQL.
- Scoped query page 50 rows p95 <=50ms trên thiết bị; cold start useful screen p95 <=2 giây là mục tiêu thử nghiệm, đo riêng DB migration.
- Không network call trùng cho cùng query/generation; số request giảm >=30% trong replay thao tác chuẩn so với baseline, không giảm freshness để đạt số đẹp.
- Test 30 phút đổi tab/scan/scroll: bộ nhớ trở về plateau, không tăng đơn điệu; report cache trong cap. Outbox không nằm trong cap đó.
- Không mất/nhân đôi giao dịch; 100% item chưa ACK có trạng thái và đường xử lý; không có fallback cache sau auth rejection.
- Telemetry chỉ enum/aggregate; thêm histogram buckets để đo p95/p99, không suy ra percentile từ average hiện có. Không ghi token/password/QR/WorkerID/raw error.

Rollout đề xuất: staging → pilot một tổ/5–10 máy ít nhất ba ca → 10% → 50% → toàn bộ, mỗi nấc ít nhất một chu kỳ vận hành đã thống nhất. Dừng rollout nếu có sai dữ liệu/quyền, lost/duplicate write, crash mới hoặc latency p95 xấu >20% so baseline. Quyết định rollback do người chịu trách nhiệm phát hành; không tự động xóa/reset DB.

Schema thay đổi theo expand/migrate, test từ v1/v2/v3 và phiên bản đã phát hành. Rollback UI bằng feature flag được nếu tương thích; nếu DB mới không đọc được bởi binary cũ thì dùng forward fix/compatibility build, không downgrade mù. Outbox luôn giữ idempotency/lineage qua update.

## 7. Nhịp nâng cấp định kỳ đề xuất

- **Mỗi PR:** format/analyze/unit/widget/integration + native build phù hợp; test security/invariant gắn với phần sửa. Chỉ merge khi checks thực sự required.
- **Hàng tuần:** triage Dependabot/OSV/CodeQL/secret alerts; patch có exploit đang diễn ra xử lý ngay, không đợi lịch. Review queue age và lỗi xác minh.
- **Hàng tháng:** release train minor/patch, replay profile PDA, cache-size/latency/crash review, kiểm tra stale-data và account switching; dành khoảng 20% capacity cho reliability.
- **Hàng quý:** đánh giá major Flutter/plugins trong PR riêng, pentest/auth/scope, kiểm tra restore/migration/rollback, quyền repository/secrets và fleet/firmware scanner.
- Chủ sở hữu rõ: Flutter lead chịu cache/frame/write correctness; SAP owner chịu authorization/idempotency/master-data contract; DevOps chịu branch/signing/gateway/rollout; QA chịu device matrix. Không tự tạo automation định kỳ từ đề xuất này.

## 8. Cách dùng skills và nguồn tham chiếu

- Đã đọc `code-review`; vì fetch/pull không tạo diff và yêu cầu là audit snapshot, không chạy/nêu kết quả hai reviewer diff giả định. `docs/agents/issue-tracker.md` không có; không chặn audit hiện tại để cài workflow phụ.
- `codebase-design`: hướng Interface của Session/WorkHistory/Mutation nhỏ, test được, giảm logic rải ở màn.
- `redesign-existing-projects`: giữ stack và nhận diện Casla; tập trung trạng thái, typography, layout và độ ổn định thay vì trang trí.
- `ui-ux-pro-max` mới thêm: đã đọc SKILL + quick-reference + pro-rules; query Flutter trả guidance keys/shared state/minimal rebuild; query touch trả 48dp Android/44pt iOS và khoảng cách. Query offline và một lần thu hẹp không có match đúng: không dùng kết quả lệch chủ đề; offline guidance dựa checklist tĩnh và audit code. Các checklist thiết bị/visual chưa chạy, được đưa vào gate C/D; không tuyên bố đã visual QA.
- Không áp các preset landing-page/GSAP/glassmorphism cho PDA Flutter. Không xóa badge pending chỉ vì người dùng đã xem; badge biểu thị giao dịch chưa ACK, không phải thông báo chưa đọc.

Nguồn chính thức đã đối chiếu:

- [Flutter — StreamBuilder lifecycle](https://api.flutter.dev/flutter/widgets/StreamBuilder-class.html): lấy stream trước build để tránh restart khi parent rebuild.
- [Flutter — Performance best practices](https://docs.flutter.dev/perf/best-practices): giảm build cost và dùng lazy list.
- [Flutter — Performance profiling](https://docs.flutter.dev/perf/ui-performance): đo profile trên thiết bị thật, không dùng debug/emulator làm kết luận release.
- [OWASP MAS — sensitive data in logs](https://mas.owasp.org/MASWE/MASVS-STORAGE/MASWE-0005/): không ghi secret vào logs, kể cả chẩn đoán.
- [OSV — querybatch](https://google.github.io/osv.dev/post-v1-querybatch/): đối chiếu package/version, giới hạn bởi dữ liệu advisory đã biết.
- [GitHub — master branch metadata](https://api.github.com/repos/nguyenduckhiem1002-dot/Android-App-Casla/branches/master): nguồn trạng thái bảo vệ nhánh tại thời điểm audit.

**Đề xuất bắt đầu:** A1–A4 và bật protection trước; song song chốt A5 với SAP owner. Sau đó B1/B2 là đợt mang lại cải thiện độ mượt và caching rõ nhất cho người dùng.

## 9. Trạng thái triển khai đợt này

Đã triển khai trong app Flutter:

- **A1:** loại bỏ log request/response có thể chứa password, token, cookie hoặc CSRF; giữ lại telemetry metadata-only và bổ sung regression tests.
- **A2:** session generation, single-flight refresh, local-first logout, chống kết quả login/refresh cũ ghi đè phiên mới, route bắt buộc đổi mật khẩu và khóa Back khi chưa hoàn tất.
- **A3:** namespace cache theo account/generation/quyền/team, scoped queue/sync feed, auth rejection xóa cache active và dừng background work theo scope.
- **A4:** kiểm tra invariant trong cùng SQLite transaction cho assignment/production/recall; chống vượt trần khi có thao tác cạnh tranh và giữ outbox/audit nhất quán.
- **B1–B3:** lịch sử/KPI dùng stream ổn định với stale-while-refresh, refresh thật, cache read atomic, retention/prune có giới hạn, pagination màn sync, lazy tabs và touch target/semantics tối thiểu cho các control chính.
- **C một phần:** CTA `Xác minh & gửi` gọi verified sync trực tiếp với password chỉ giữ trong memory; item không còn bị báo thành công giả hoặc bị retry nền vô hạn khi thiếu xác minh.
- **QR thực tế:** parser công nhân nhận mã hỗn hợp như `A1`, `bachdv`, `NC000002`, `2`, đọc `ValidFrom/ValidTo` và chặn scan ngoài hiệu lực; parser công đoạn giữ raw payload, tên hàng và khóa `ProductionOrder/Operation`. Schema v4 lưu validity window công nhân và `operation_qr_payload` để retry/sync không mất thông tin QR.

Kiểm chứng sau triển khai:

- `flutter analyze --no-pub`: **No issues found**.
- `flutter test --no-pub`: **203 tests passed** ở vòng hiện tại, gồm auth race, scope isolation, transaction invariant, cache stream, SAP chaos, offline restart, verified sync, QR parser/validity, schema migration, operation QR lookup, overview team-scope alias và performance benchmark.
- `git diff --check`: không phát hiện whitespace error.

Các phần chưa thể hoàn tất chỉ bằng app và cần phối hợp ngoài code:

- **ABAP contract (đã xác nhận, không phải blocker):** backend bắt buộc `WorkerPassword` trên `initialAssign`, `transfer`, `recall`, `confirm` để công nhân xác nhận việc nhận sản phẩm và xác nhận công đoạn. App giữ nguyên quy tắc này: mở dialog xác minh ở foreground, chỉ truyền password cho request hiện tại, không lưu lại và hiển thị CTA xử lý lại nếu giao dịch offline/chưa được xác minh.
- **Master-data bootstrap:** backend clone hiện chưa có endpoint revision/bootstrap đủ để app tải catalog khi cài mới; app đã fail-closed và hiển thị hướng dẫn rõ thay vì giả tạo dữ liệu.
- **Release governance/visual QA:** branch protection, signed staging, device matrix, profile-mode frame metrics và pilot rollout cần được thực hiện bởi DevOps/QA/SAP owner theo gate D; không được suy ra từ test local.

Không thay đổi mã ABAP trong đợt này. Các file `.abap_security_review/`, `.tmp_abap_rap100/`, `.claude/` và trạng thái submodule đã tồn tại ngoài phạm vi app được giữ nguyên.

## 10. Đợt tiếp tục — bảo vệ xác minh và giảm tải đọc dữ liệu

Triển khai tiếp trên commit `b499bb5`:

- `SyncAccessScope` chứa session generation và danh sách team bất biến. Chuỗi xác minh/background sync dừng khi đăng nhập lại cùng tài khoản; kiểm tra lại sau đọc nguồn và sau refresh trước khi gửi. Sửa race stop/start của subscription kết nối.
- S07/S08/S09 khóa thao tác trước khi mở dialog, mở khóa khi hủy/lỗi và kiểm tra phiên/team sau khi nhập password. S08 ngăn mở lặp sheet nhập sản lượng. S12 không tiếp tục xác minh từ dialog của phiên cũ.
- Dialog worker password chỉ đóng một lần khi Enter và nút gửi được kích hoạt sát nhau, xóa controller khi đóng. Login chặn gửi lặp và tránh truy cập controller sau dispose.
- Repository assignment chỉ đọc thông tin hiển thị và KPI của các ID đã chọn. SQLite dùng index hiện có cho tổng production/recall, đọc một snapshot transaction và chia chunk 400 ID để tránh giới hạn tham số. Giữ thứ tự danh sách, không nhân tổng do join hai bảng chi tiết.
- Stream lịch sử phát lỗi refresh cho query tương ứng, giữ snapshot đã tải để UI hiển thị cảnh báo bản lưu và phát dữ liệu mới khi mạng phục hồi. Buffer update trong lần đọc đầu để cache cũ không ghi đè kết quả refresh nhanh.

Kiểm chứng: analyzer sạch; full Flutter suite **194 tests passed**, gồm regression cho session/scope giữa sync, SQL display/chunk, cache error/recovery, dialog double-submit, keyset pagination, cache retention và quantity formatting. Đã format các file sửa và kiểm tra whitespace. Chưa đo frame timing trên thiết bị thật.

Phạm vi còn lại của plan (các mục này cần thêm QA/backend/DevOps hoặc một PR riêng):

- UX-03: W01 đã có lazy `SliverList` ở phía app; còn cần mở rộng contract của OData V4 static action `getWorkHistory` để nhận page size/cursor (hoặc thêm entity collection query) và trả `nextCursor/hasMore`; S12 queue đã có pagination end-to-end.
- UX-02/06: đối soát KPI SAP/local pending bằng transaction ID, invalidation sau ACK/resume và quyết định chính sách giữ subscription ở tab ẩn.
- UX-05: chạy profile dữ liệu thật để xác nhận cap xấp xỉ 25MB, chi phí prune và điều chỉnh LRU theo pilot.
- UX-07/08/09: typography/font chính thức, visual QA text scale/TalkBack/landscape, state restoration đầy đủ và workflow sửa giao dịch bị từ chối có audit.
- Bootstrap master data còn cần contract backend; staging, branch protection và device/pilot gates còn cần môi trường vận hành. `WorkerPassword` là quy tắc nghiệp vụ đã chốt và được giữ nguyên.

## 11. Đợt tiếp tục — range tổng quan quản lý và hiển thị đủ tổ

Đã triển khai trên app Flutter:

- S06 có bộ chọn `Một ngày`, `Tuần này`, `Tháng này` và `Tùy chọn`; request dùng đúng `RangeCode` của OData `getWorkHistory` (`D/W/M/C`). Khoảng ngày custom giới hạn 31 ngày để giữ trải nghiệm và tải dữ liệu ổn định.
- KPI, danh sách công nhân và assignment local dùng cùng một khoảng thời gian. Khi đổi range, stream query được thay thế có chủ đích để tránh hiển thị lẫn dữ liệu của range trước.
- Scope tổ được resolve ở database theo cả khóa local (`team-1`) và mã nghiệp vụ SAP (`ma_to`, ví dụ `TC01`). Cùng một logic được dùng cho worker và assignment, nên “Tất cả tổ” không còn bị rỗng chỉ vì khác dạng mã.
- Nếu master team local chưa có bản ghi tương ứng, bộ lọc vẫn hiển thị các mã tổ SAP trong phạm vi phiên và không tự mở rộng ra ngoài scope.
- Bổ sung regression test cho worker/assignment/team lookup bằng mã SAP.

Kiểm chứng sau đợt này:

- `flutter analyze --no-pub`: **No issues found**.
- `flutter test --no-pub test/core/scope_and_order_lookup_test.dart`: **23 tests passed**.
- `flutter test --no-pub`: **203 tests passed**.
- `git diff --check`: không phát hiện whitespace error; cảnh báo còn lại chỉ là chuyển đổi line ending LF/CRLF của Git trên Windows.
