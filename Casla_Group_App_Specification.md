**CASLA GROUP**

ĐẶC TẢ SẢN PHẨM & KỸ THUẬT

Ứng dụng ghi nhận sản lượng Flutter cross-platform

**PHẠM VI CHỐT** Phân công bởi Supervisor · Ghi nhận theo ngày sản xuất/ca · Thu hồi phần chưa làm · Thiết bị dùng chung · Offline tối đa không làm mất dữ liệu

Phiên bản 1.0 · 05/08/2026

# Kiểm soát tài liệu

| **Thuộc tính**                    | **Giá trị**                                         |
| --------------------------------- | --------------------------------------------------- |
| Tên tài liệu                      | Đặc tả sản phẩm và kỹ thuật - App Casla Group       |
| Phiên bản                         | 1.0                                                 |
| Trạng thái                        | Bản cơ sở để duyệt nghiệp vụ và triển khai MVP      |
| Nền tảng                          | Flutter - Android trước, mở rộng iOS/Windows tablet |
| Nguồn dữ liệu giai đoạn đầu       | Mock + Drift/SQLite                                 |
| Nguồn dữ liệu đích                | SAP OData/RAP                                       |
| Múi giờ hiển thị                  | Asia/Ho_Chi_Minh                                    |
| Đơn vị chịu trách nhiệm nghiệp vụ | Casla Group                                         |

# Mục lục nội dung

| **Phần** | **Nội dung**               |
| -------- | -------------------------- |
| 1        | Mục tiêu và nguyên tắc     |
| 2        | Vai trò và phân quyền      |
| 3        | Mô hình nghiệp vụ          |
| 4        | Quy trình đầu-cuối         |
| 5        | UI/UX và danh mục màn hình |
| 6        | Design system              |
| 7        | Kiến trúc ứng dụng         |
| 8        | Schema và database         |
| 9        | Đồng bộ và SAP             |
| 10       | Kiểm thử và nghiệm thu     |
| 11       | Lộ trình phát triển        |
| 12       | Phụ lục API/SQL            |

# 1\. Mục tiêu và nguyên tắc

Ứng dụng ghi nhận số lượng được Supervisor giao cho công nhân và sản lượng công nhân hoàn thành qua nhiều lần, nhiều ngày. Hệ thống không quản lý routing/công đoạn, không cảnh báo trễ và không suy diễn tiến độ kế hoạch.

| **Mục tiêu**      | **Kết quả kỳ vọng**                                                                   |
| ----------------- | ------------------------------------------------------------------------------------- |
| Nhanh             | Quét và lưu local ngay; UI phản hồi tức thời.                                         |
| Đúng              | Không cho ghi nhận vượt phần còn lại; mọi tổng hợp dựa trên giao dịch.                |
| Truy vết          | Không xóa giao dịch nghiệp vụ; mọi thu hồi có người, lý do, ngày, ca và thiết bị.     |
| An toàn quyền     | Công nhân chỉ xem mình; Supervisor/Kiểm tra theo quyền chi tiết và phạm vi tổ từ SAP. |
| Sẵn sàng SAP      | UI phụ thuộc repository nghiệp vụ, không phụ thuộc trực tiếp endpoint OData.          |
| Không mất dữ liệu | Bản ghi chưa đồng bộ được giữ đến khi SAP xác nhận thành công.                        |

**QUYẾT ĐỊNH CỐT LÕI** Phân công có thể tồn tại xuyên ngày. Nhật ký được thống kê theo ngày sản xuất và ca; công nhân vẫn ghi nhận ngày hôm sau nếu phân công còn hiệu lực.

# 2\. Vai trò và phân quyền

| **Vai trò**     | **Trách nhiệm**                                                       | **Phạm vi dữ liệu**                         |
| --------------- | --------------------------------------------------------------------- | ------------------------------------------- |
| Công nhân       | Xem phân công, ghi nhận sản lượng, xem lịch sử của mình.              | Chỉ MaNV của phiên hiện tại.                |
| Supervisor      | Phân công, xem tổ phụ trách, thu hồi phần chưa làm, theo dõi đồng bộ. | Các tổ và quyền chi tiết SAP cấp.           |
| Kiểm tra (KTOA) | Quét nhân viên và xem kết quả thực tế/lịch sử.                        | Theo VIEW_TEAM_PRODUCTION hoặc phạm vi SAP. |
| Quản trị SAP    | Quản lý danh tính, tổ, quyền, danh mục, đơn hàng và tích hợp.         | Theo backend SAP.                           |

## 2.1 Ma trận quyền chi tiết

| **Permission**        | **Công nhân**    | **Supervisor** | **Kiểm tra**  |
| --------------------- | ---------------- | -------------- | ------------- |
| VIEW_OWN_PRODUCTION   | Có               | Có             | Có            |
| RECORD_OWN_PRODUCTION | Có               | Tùy cấu hình   | Không         |
| ASSIGN_QUANTITY       | Không            | Có             | Không         |
| RECALL_ASSIGNMENT     | Không            | Có             | Tùy cấu hình  |
| VIEW_TEAM_PRODUCTION  | Không            | Có             | Có            |
| VIEW_EMPLOYEE_HISTORY | Chỉ bản thân     | Trong phạm vi  | Trong phạm vi |
| VIEW_SYNC_STATUS      | Bản ghi của mình | Có             | Tùy cấu hình  |
| SWITCH_USER           | Có               | Có             | Có            |

Mã badge chứa trực tiếp MaNV nhưng chỉ là dữ liệu nhận diện. Quyền cuối cùng đến từ phiên xác thực và danh sách permission SAP. Supervisor nên xác thực bằng PIN hoặc đăng nhập SAP để tránh giả mạo badge.

# 3\. Mô hình nghiệp vụ

## 3.1 Khái niệm và công thức

| **Chỉ số**         | **Công thức/ý nghĩa**                                               |
| ------------------ | ------------------------------------------------------------------- |
| Giao ban đầu       | Tổng số lượng Supervisor đã phân công.                              |
| Đã thu hồi         | Tổng ThuHoiPhanCong hợp lệ.                                         |
| Giao hiệu lực      | Giao ban đầu − Đã thu hồi.                                          |
| Hoàn thành lũy kế  | Tổng GhiNhanSanLuong hợp lệ của phân công.                          |
| Hoàn thành theo kỳ | Tổng sản lượng có businessDate/ca nằm trong bộ lọc.                 |
| Còn lại            | Giao hiệu lực − Hoàn thành lũy kế.                                  |
| Có thể thu hồi     | Giao ban đầu − Hoàn thành lũy kế − Đã thu hồi.                      |
| Tỷ lệ              | Hoàn thành lũy kế / Giao hiệu lực; bằng 0 nếu giao hiệu lực bằng 0. |

effectiveAssigned = assignedQuantity - recalledQuantity  
remaining = effectiveAssigned - completedQuantity  
maxRecall = assignedQuantity - completedQuantity - recalledQuantity  
0 < newCompletion <= remaining  
0 < newRecall <= maxRecall

## 3.2 Trạng thái phân công

| **Trạng thái** | **Điều kiện**                       | **Cho ghi nhận** |
| -------------- | ----------------------------------- | ---------------- |
| OPEN           | Còn số lượng và chưa đóng.          | Có               |
| COMPLETED      | Còn lại = 0 do hoàn thành.          | Không            |
| RECALLED       | Còn lại = 0 do thu hồi.             | Không            |
| CLOSED         | Supervisor/SAP đóng theo nghiệp vụ. | Không            |
| SUSPENDED      | Tạm dừng từ SAP.                    | Không            |

## 3.3 Ngày sản xuất và ca đêm

Mỗi giao dịch lưu occurredAt theo UTC, businessDate theo ngày sản xuất, shiftId theo ca. Ca qua 0 giờ thuộc ngày bắt đầu ca. Ví dụ ca 22:00-06:00 bắt đầu 05/08: giao dịch 02:00 ngày 06/08 vẫn có businessDate = 05/08.

| **Trường**    | **Mục đích**                              |
| ------------- | ----------------------------------------- |
| occurredAtUtc | Sự kiện thực tế và thứ tự tuyệt đối.      |
| businessDate  | Tổng hợp báo cáo ngày sản xuất.           |
| shiftId       | Tổng hợp theo ca và xác định ca qua ngày. |
| createdAtUtc  | Thời điểm thiết bị tạo bản ghi.           |
| syncedAtUtc   | Thời điểm SAP xác nhận.                   |

# 4\. Quy trình nghiệp vụ đầu-cuối

## 4.1 Đăng nhập và đổi người dùng trên thiết bị dùng chung

| **Bước** | **Thao tác**                                  | **Kiểm tra hệ thống**                | **Kết quả**               |
| -------- | --------------------------------------------- | ------------------------------------ | ------------------------- |
| 1        | Màn hình sẵn sàng quét.                       | Không hiển thị dữ liệu người trước.  | Focus nhận PDA hoạt động. |
| 2        | Quét badge chứa MaNV.                         | Tra cache; nếu có mạng xác thực SAP. | Nhận diện nhân viên.      |
| 3        | Nếu là Supervisor/Kiểm tra, xác thực bổ sung. | Kiểm tra token và quyền chi tiết.    | Tạo phiên.                |
| 4        | Tải phạm vi tổ và dữ liệu cần thiết.          | Áp dụng route guard.                 | Mở đúng dashboard.        |
| 5        | Chọn Đổi người dùng/timeout.                  | Đóng phiên, xóa state nhạy cảm.      | Trở lại màn hình quét.    |

## 4.2 Supervisor tạo phân công

| **Bước** | **UI**                         | **Quy tắc**                                                |
| -------- | ------------------------------ | ---------------------------------------------------------- |
| 1        | Chọn "Phân công".              | Yêu cầu ASSIGN_QUANTITY.                                   |
| 2        | Quét/chọn công nhân.           | Nhân viên phải thuộc tổ được quản lý.                      |
| 3        | Quét/chọn đơn hàng/SP.         | Đơn hàng đang mở.                                          |
| 4        | Nhập số lượng và ngày bắt đầu. | Số lượng > 0, đúng đơn vị tính.                            |
| 5        | Xác nhận.                      | Lưu PhanCong + AuditLog + SyncQueue trong một transaction. |
| 6        | Hiển thị kết quả.              | UI cập nhật ngay; SAP đồng bộ nền.                         |

## 4.3 Công nhân ghi nhận sản lượng

| **Bước** | **UI**                              | **Quy tắc**                                         |
| -------- | ----------------------------------- | --------------------------------------------------- |
| 1        | Chọn phân công đang mở.             | Chỉ phân công của MaNV phiên hiện tại.              |
| 2        | Xem giao hiệu lực, lũy kế, còn lại. | Tổng hợp từ DB local.                               |
| 3        | Nhập số vừa hoàn thành.             | Số nguyên/décimal theo UoM; >0 và ≤ còn lại.        |
| 4        | Xác nhận.                           | Hiển thị nhân viên, đơn hàng, số lượng, ca/ngày.    |
| 5        | Lưu.                                | Atomic transaction: GhiNhan + SyncQueue + AuditLog. |
| 6        | Tiếp tục hoặc kết thúc.             | Focus trở lại thao tác chính.                       |

## 4.4 Chuyển tồn sang ngày hôm sau

Không tạo thu hồi chỉ vì hết ngày hoặc hết ca. Phân công OPEN vẫn xuất hiện ngày hôm sau. Dashboard hôm nay hiển thị sản lượng riêng ngày/ca; thẻ lũy kế giữ tổng từ đầu phân công. Supervisor chỉ thu hồi khi quyết định công nhân không tiếp tục làm phần còn lại.

## 4.5 Supervisor thu hồi phần chưa làm

| **Bước** | **UI**                               | **Quy tắc**                                  |
| -------- | ------------------------------------ | -------------------------------------------- |
| 1        | Mở chi tiết phân công, chọn Thu hồi. | Yêu cầu RECALL_ASSIGNMENT.                   |
| 2        | Xem số có thể thu hồi.               | assigned − completed − recalled.             |
| 3        | Nhập số lượng và lý do.              | 0 < số thu hồi ≤ maxRecall; lý do bắt buộc.  |
| 4        | Xác nhận lần cuối.                   | Hiển thị tác động đến giao hiệu lực/còn lại. |
| 5        | Lưu giao dịch thu hồi.               | Không sửa/xóa phân công gốc.                 |
| 6        | Đồng bộ.                             | Idempotency key; lỗi vẫn giữ local.          |

## 4.6 Kiểm tra nhân viên

Người có quyền Kiểm tra quét MaNV, hệ thống xác minh phạm vi rồi hiển thị dashboard. Nhật ký truy cập ghi actorId, targetEmployeeId, thời gian và thiết bị. Nếu ngoài phạm vi, từ chối và vẫn ghi AuditLog.

## 4.7 Đồng bộ offline

| **Tình huống**     | **Ứng xử**                                                        |
| ------------------ | ----------------------------------------------------------------- |
| Có mạng/API tốt    | Lưu local → gửi ngay → SYNCED → cache lịch sử tối thiểu một ngày. |
| Mất mạng           | Lưu local → PENDING → tiếp tục thao tác.                          |
| Có kết nối lại     | Worker gửi theo thứ tự nghiệp vụ, dùng idempotencyKey.            |
| Lỗi tạm thời       | Retry với backoff; hiển thị số bản ghi chờ.                       |
| Lỗi nghiệp vụ      | FAILED, không retry vô hạn; Supervisor xử lý.                     |
| Pending quá 24 giờ | Không xóa; cảnh báo Supervisor và giữ đến khi SAP xác nhận.       |

# 5\. Kiến trúc thông tin và UI/UX

## 5.1 Điều hướng theo vai trò

| **Vai trò** | **Tab 1** | **Tab 2** | **Tab 3** | **Tab 4** |
| ----------- | --------- | --------- | --------- | --------- |
| Công nhân   | Hôm nay   | Ghi nhận  | Lịch sử   | Tài khoản |
| Supervisor  | Tổng quan | Phân công | Đồng bộ   | Tài khoản |
| Kiểm tra    | Kiểm tra  | Gần đây   | Đồng bộ   | Tài khoản |

## 5.2 Danh mục màn hình

| **ID** | **Màn hình**         | **Mục tiêu**                  | **Thành phần chính**                      |
| ------ | -------------------- | ----------------------------- | ----------------------------------------- |
| S01    | Khởi động            | Khởi tạo DB, session, config. | Loading, lỗi khởi tạo, retry.             |
| S02    | Quét/đăng nhập       | Nhận MaNV và xác thực.        | Scanner field, camera, nhập tay có quyền. |
| S03    | Hôm nay - Công nhân  | Tóm tắt ngày/ca và phân công. | 4 KPI, danh sách đơn hàng, nút ghi nhận.  |
| S04    | Ghi nhận sản lượng   | Nhập và lưu sản lượng.        | Thông tin cố định, keypad số, xác nhận.   |
| S05    | Lịch sử cá nhân      | Xem log theo ngày/ca/kỳ.      | Filter chip, tổng hợp, timeline.          |
| S06    | Tổng quan Supervisor | Theo dõi các tổ được quản lý. | Bộ lọc tổ/ca/ngày, danh sách nhân viên.   |
| S07    | Tạo phân công        | Giao số lượng.                | Quét nhân viên, đơn hàng, số lượng.       |
| S08    | Chi tiết phân công   | Xem lũy kế và giao dịch.      | KPI, lịch sử, Thu hồi.                    |
| S09    | Thu hồi              | Thu hồi phần chưa làm.        | Max recall, số lượng, lý do, xác nhận.    |
| S10    | Kiểm tra nhân viên   | Quét và xem nhân viên.        | Scanner, danh sách gần đây.               |
| S11    | Dashboard kiểm tra   | Xem kết quả người được quét.  | KPI, bảng đơn hàng, lịch sử.              |
| S12    | Đồng bộ              | Quản lý pending/failed.       | Tab trạng thái, retry, chi tiết lỗi.      |
| S13    | Tài khoản            | Thông tin phiên và đổi người. | Quyền, thiết bị, sync cuối, logout.       |
| S14    | Không có quyền       | Chặn truy cập.                | Thông báo + quay lại.                     |
| S15    | Chọn ca/ngày         | Lọc theo businessDate/shift.  | Date picker, ca, preset nhanh.            |

## 5.3 Đặc tả UI từng màn hình trọng yếu

### S03 - Hôm nay của công nhân

| **Khu vực** | **Nội dung**                                        | **Hành vi**                                 |
| ----------- | --------------------------------------------------- | ------------------------------------------- |
| App bar     | Tên, MaNV, tổ, ngày sản xuất, ca.                   | Luôn hiển thị danh tính; chạm để đổi người. |
| KPI         | Giao hiệu lực; hoàn thành hôm nay; lũy kế; còn lại. | Số lớn, nhãn rõ; không cảnh báo trễ.        |
| Phân công   | Mã đơn, sản phẩm, giao, hoàn thành, còn lại.        | OPEN trước; chạm mở S04.                    |
| Sync banner | Số bản ghi chờ/lỗi.                                 | Ẩn khi tất cả SYNCED; chạm mở S12.          |
| Empty state | Không có phân công đang mở.                         | Cho tải lại/đổi người dùng.                 |

### S04 - Ghi nhận sản lượng

| **Thành phần** | **Quy định**                                                           |
| -------------- | ---------------------------------------------------------------------- |
| Khóa ngữ cảnh  | Tên NV, đơn hàng, SP, đơn vị tính, ca/ngày phải cố định trên màn hình. |
| Số liệu        | Hiện giao hiệu lực, hoàn thành lũy kế và còn lại trước khi nhập.       |
| Ô số lượng     | Bàn phím số; auto-select; không cho dấu âm; decimal theo UoM.          |
| Nút nhanh      | Có thể cấu hình +10/+50/+100; không vượt remaining.                    |
| CTA            | "Lưu ghi nhận", cao tối thiểu 56dp, gold trên navy/white.              |
| Xác nhận       | Bottom sheet nhắc lại MaNV, đơn hàng, số lượng, ca/ngày.               |
| Thành công     | Rung nhẹ, âm thanh, snackbar, KPI cập nhật ngay.                       |
| Lỗi            | Giữ dữ liệu nhập; nêu nguyên nhân và cách xử lý.                       |

### S07 - Tạo phân công

| **Trường**    | **Bắt buộc** | **Nguồn/validation**              |
| ------------- | ------------ | --------------------------------- |
| Công nhân     | Có           | Quét MaNV; thuộc SupervisorScope. |
| Đơn hàng      | Có           | SAP/cache; trạng thái OPEN.       |
| Sản phẩm      | Tự động      | Theo đơn hàng.                    |
| Số lượng giao | Có           | \>0; theo UoM.                    |
| Ngày bắt đầu  | Có           | Mặc định businessDate hiện tại.   |
| Ca            | Có           | Ca hiện tại hoặc được chọn.       |
| Ghi chú       | Không        | Giới hạn độ dài cấu hình.         |

### S09 - Thu hồi

| **Thành phần** | **Nội dung**                                              |
| -------------- | --------------------------------------------------------- |
| Tóm tắt        | Giao ban đầu, đã hoàn thành, đã thu hồi, có thể thu hồi.  |
| Số thu hồi     | Không vượt maxRecall.                                     |
| Lý do          | Không làm hết; điều chuyển; đổi kế hoạch; kết thúc; khác. |
| Ghi chú        | Bắt buộc khi chọn Khác.                                   |
| Tác động       | Xem trước giao hiệu lực và còn lại sau thu hồi.           |
| CTA            | "Xác nhận thu hồi"; yêu cầu xác nhận lần hai.             |
| Kết quả        | Tạo ThuHoiPhanCong, AuditLog, SyncQueue.                  |

## 5.4 Trạng thái chung

| **State**       | **Hiển thị**                                | **Hành động**            |
| --------------- | ------------------------------------------- | ------------------------ |
| Loading         | Skeleton, không spinner toàn trang kéo dài. | Chờ/tải nền.             |
| Empty           | Minh họa nhẹ + thông điệp cụ thể.           | Tải lại, đổi bộ lọc.     |
| Offline         | Banner gold: dữ liệu sẽ đồng bộ sau.        | Vẫn cho nghiệp vụ local. |
| Pending         | Biểu tượng đồng hồ + số bản ghi.            | Mở trạng thái sync.      |
| Failed          | Nhãn đỏ + lỗi thân thiện.                   | Thử lại/xem chi tiết.    |
| Unauthorized    | Không lộ dữ liệu đích.                      | Quay lại/đổi người.      |
| Session expired | Khóa nội dung nhạy cảm.                     | Đăng nhập lại.           |

# 6\. Design system

## 6.1 Màu sắc

| **Token**    | **Hex** | **Ứng dụng**                           |
| ------------ | ------- | -------------------------------------- |
| Primary Navy | #16234A | App bar, heading, navigation, nền đậm. |
| Accent Gold  | #C9A24B | CTA, focus, trạng thái pending.        |
| Surface      | #FFFFFF | Nền card và form.                      |
| Background   | #F5F6F8 | Nền màn hình.                          |
| Muted        | #8A8F9B | Text phụ, border.                      |
| Success      | #2E7D32 | Ghi nhận thành công/SYNCED.            |
| Danger       | #C62828 | Thu hồi, lỗi, thao tác rủi ro.         |

## 6.2 Typography và spacing

| **Vai trò**    | **Cỡ/weight** | **Ứng dụng**                           |
| -------------- | ------------- | -------------------------------------- |
| Display number | 32-36sp / 700 | KPI chính.                             |
| Screen title   | 22-24sp / 700 | Tiêu đề màn hình.                      |
| Section title  | 18-20sp / 600 | Nhóm nội dung.                         |
| Body           | 16-18sp / 400 | Nội dung vận hành.                     |
| Label          | 14-16sp / 600 | Nhãn form/nút.                         |
| Caption        | 14sp / 400    | Metadata; không nhỏ hơn 14sp trên PDA. |

Dùng lưới 4dp; khoảng cách phổ biến 8/12/16/24/32dp. Vùng chạm tối thiểu 48×48dp; nút nghiệp vụ chính cao 56-60dp. Không dùng màu làm tín hiệu duy nhất.

## 6.3 Component library

| **Component**       | **Yêu cầu**                                                    |
| ------------------- | -------------------------------------------------------------- |
| EmployeeIdentityBar | Tên, MaNV, tổ và nút đổi người; luôn rõ trên thiết bị chung.   |
| KpiCard             | Nhãn + số + UoM; không dùng biểu đồ nếu số trực tiếp đủ rõ.    |
| AssignmentCard      | Đơn hàng/SP, giao hiệu lực, lũy kế, còn lại, lần ghi gần nhất. |
| ScannerInput        | Focus bền vững, buffer, Enter terminator, chống trùng.         |
| QuantityKeypad      | Số lớn, xóa nhanh, nút preset có validation.                   |
| SyncStatusChip      | PENDING/SYNCING/SYNCED/FAILED với icon + text.                 |
| DateShiftFilter     | Ngày sản xuất + ca; preset Hôm nay/Hôm qua/7 ngày.             |
| ConfirmSheet        | Tóm tắt hành động và hậu quả; CTA rõ.                          |
| ReasonPicker        | Danh sách lý do; ghi chú bắt buộc cho Khác.                    |
| TransactionTimeline | Nhóm ngày, giờ, loại, số lượng, actor, sync status.            |

## 6.4 Quét mã

| **Kênh**            | **Thiết kế**                                                                                    |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| PDA keyboard wedge  | Tích lũy ký tự đến Enter; đo khoảng ký tự; tự focus lại; không bật bàn phím ảo không cần thiết. |
| Camera              | mobile_scanner; scan window; bật torch; giới hạn format thực tế.                                |
| Phản hồi thành công | Rung nhẹ + âm ngắn + viền xanh + nội dung vừa quét.                                             |
| Phản hồi lỗi        | Rung khác nhịp + âm lỗi + viền đỏ + nguyên nhân.                                                |
| Chống trùng         | Debounce theo code + thời gian; không tự tạo hai giao dịch.                                     |

# 7\. Kiến trúc ứng dụng

Presentation (Flutter screens/widgets)  
↓  
Application (Riverpod controllers + use cases)  
↓  
Domain (entities + repository contracts + policies)  
↓  
Data (repository implementations)  
├─ Local: Drift/SQLite  
├─ Remote: Mock API / SAP OData-RAP  
└─ Sync engine + secure session

## 7.1 Module

| **Module**  | **Trách nhiệm**                         |
| ----------- | --------------------------------------- |
| auth        | Phiên, MaNV, quyền chi tiết, đổi người. |
| employees   | Nhân viên, tổ, phạm vi Supervisor.      |
| orders      | Đơn hàng, sản phẩm, UoM.                |
| assignments | Tạo/xem/đóng phân công.                 |
| production  | Ghi nhận và tổng hợp sản lượng.         |
| recall      | Thu hồi phần chưa làm.                  |
| inspection  | Quét và xem nhân viên khác theo quyền.  |
| shift       | Ca và businessDate.                     |
| scanner     | Camera + keyboard wedge adapter.        |
| sync        | Queue, retry, conflict, idempotency.    |
| audit       | Nhật ký hành động.                      |
| settings    | Thiết bị, cấu hình, retention.          |

## 7.2 Thư viện

| **Package**                            | **Mục đích**                                 | **Ghi chú**                         |
| -------------------------------------- | -------------------------------------------- | ----------------------------------- |
| flutter_riverpod / riverpod_annotation | State, DI, async controllers.                | Khóa phiên bản khi khởi tạo.        |
| drift / drift_flutter / drift_dev      | SQLite type-safe, query reactive, migration. | Nguồn local chính.                  |
| go_router                              | Điều hướng và route guard.                   | Guard theo session/permission.      |
| mobile_scanner                         | Quét camera.                                 | Android trước.                      |
| dio                                    | HTTP/OData, interceptor, timeout.            | Không log token.                    |
| connectivity_plus                      | Tín hiệu thay đổi kết nối.                   | Không coi là bằng chứng API online. |
| freezed / json_serializable            | Model immutable và JSON.                     | Code generation.                    |
| flutter_secure_storage                 | Token/secret phiên.                          | Không lưu nghiệp vụ.                |
| uuid                                   | ID local/idempotency key.                    | UUID v4/v7 tùy chuẩn.               |
| intl                                   | Ngày giờ/UoM.                                | Locale vi_VN.                       |
| device_info_plus / package_info_plus   | Thiết bị và phiên bản.                       | Audit/support.                      |
| logger                                 | Log dev có redaction.                        | Tắt payload nhạy cảm production.    |

Nguồn tham khảo package chính thức: <https://pub.dev/packages/flutter_riverpod> · <https://pub.dev/packages/drift> · <https://pub.dev/packages/mobile_scanner> · <https://pub.dev/packages/go_router> · <https://pub.dev/packages/dio>

## 7.3 Cấu trúc source

lib/  
app/ (router, theme, bootstrap)  
core/ (database, network, scanner, sync, auth, errors)  
features/  
authentication/ employees/ orders/ assignments/  
production/ recall/ inspection/ history/ sync_status/  
shared/ (widgets, models, formatters)

# 8\. Data model và database

## 8.1 Quan hệ logic

NhanVien ──&lt; PhanCong &gt;── DonHang  
│ │  
│ ├──< GhiNhanSanLuong  
│ └──< ThuHoiPhanCong  
├──&lt; NhanVienTo &gt;── ToSanXuat  
└──&lt; SupervisorScope &gt;── ToSanXuat  
CaLamViec ──< mọi giao dịch nghiệp vụ  
Mọi giao dịch ──< SyncQueue / AuditLog

## 8.2 Bảng NhanVien

| **Cột**        | **Kiểu/ràng buộc**   | **Ý nghĩa**   |
| -------------- | -------------------- | ------------- |
| id             | TEXT PK              | UUID local    |
| ma_nv          | TEXT NOT NULL UNIQUE | Mã SAP/badge  |
| ten            | TEXT NOT NULL        | Họ tên        |
| bo_phan        | TEXT                 | Bộ phận       |
| trang_thai     | TEXT NOT NULL        | ACTIVE/LOCKED |
| sap_id         | TEXT                 | Khóa SAP      |
| updated_at_utc | INTEGER              | Epoch ms      |

## 8.3 Bảng ToSanXuat

| **Cột**    | **Kiểu/ràng buộc**   | **Ý nghĩa**     |
| ---------- | -------------------- | --------------- |
| id         | TEXT PK              | UUID            |
| ma_to      | TEXT UNIQUE NOT NULL | Mã tổ           |
| ten_to     | TEXT NOT NULL        | Tên tổ          |
| bo_phan    | TEXT                 | Bộ phận         |
| trang_thai | TEXT NOT NULL        | ACTIVE/INACTIVE |
| sap_id     | TEXT                 | Khóa SAP        |

## 8.4 Bảng NhanVienTo

| **Cột**      | **Kiểu/ràng buộc** | **Ý nghĩa**       |
| ------------ | ------------------ | ----------------- |
| id           | TEXT PK            | UUID              |
| nhan_vien_id | TEXT FK            | Nhân viên         |
| to_id        | TEXT FK            | Tổ                |
| valid_from   | TEXT               | Ngày hiệu lực     |
| valid_to     | TEXT               | Ngày hết hiệu lực |
| sap_id       | TEXT               | Khóa SAP          |

## 8.5 Bảng SupervisorScope

| **Cột**         | **Kiểu/ràng buộc** | **Ý nghĩa**     |
| --------------- | ------------------ | --------------- |
| id              | TEXT PK            | UUID            |
| supervisor_id   | TEXT FK            | Supervisor      |
| to_id           | TEXT FK            | Tổ quản lý      |
| permission_json | TEXT NOT NULL      | Danh sách quyền |
| valid_from      | TEXT               | Hiệu lực từ     |
| valid_to        | TEXT               | Hiệu lực đến    |
| updated_at_utc  | INTEGER            | Cache timestamp |

## 8.6 Bảng DonHang

| **Cột**        | **Kiểu/ràng buộc**   | **Ý nghĩa**           |
| -------------- | -------------------- | --------------------- |
| id             | TEXT PK              | UUID                  |
| ma_don_hang    | TEXT UNIQUE NOT NULL | Mã đơn                |
| ma_sp          | TEXT NOT NULL        | Mã SP                 |
| ten_sp         | TEXT NOT NULL        | Tên SP                |
| uom            | TEXT NOT NULL        | Đơn vị tính           |
| so_luong_don   | REAL NOT NULL        | Tổng đơn              |
| trang_thai     | TEXT NOT NULL        | OPEN/CLOSED/SUSPENDED |
| sap_id         | TEXT                 | Khóa SAP              |
| updated_at_utc | INTEGER              | Cập nhật              |

## 8.7 Bảng CaLamViec

| **Cột**        | **Kiểu/ràng buộc**   | **Ý nghĩa**      |
| -------------- | -------------------- | ---------------- |
| id             | TEXT PK              | UUID             |
| ma_ca          | TEXT UNIQUE NOT NULL | Mã ca            |
| ten_ca         | TEXT NOT NULL        | Tên ca           |
| start_minute   | INTEGER NOT NULL     | Phút từ 00:00    |
| end_minute     | INTEGER NOT NULL     | Phút từ 00:00    |
| cross_midnight | INTEGER NOT NULL     | 0/1              |
| timezone       | TEXT NOT NULL        | Asia/Ho_Chi_Minh |
| trang_thai     | TEXT NOT NULL        | ACTIVE/INACTIVE  |

## 8.8 Bảng PhanCong

| **Cột**           | **Kiểu/ràng buộc**     | **Ý nghĩa** |
| ----------------- | ---------------------- | ----------- |
| id                | TEXT PK                | UUID        |
| nhan_vien_id      | TEXT FK NOT NULL       | Người nhận  |
| don_hang_id       | TEXT FK NOT NULL       | Đơn hàng    |
| to_id             | TEXT FK NOT NULL       | Tổ          |
| assigned_quantity | REAL NOT NULL CHECK >0 | Số giao     |
| business_date     | TEXT NOT NULL          | YYYY-MM-DD  |
| shift_id          | TEXT FK NOT NULL       | Ca          |
| status            | TEXT NOT NULL          | OPEN/...    |
| note              | TEXT                   | Ghi chú     |
| created_by        | TEXT NOT NULL          | Supervisor  |
| occurred_at_utc   | INTEGER NOT NULL       | Thời điểm   |
| device_id         | TEXT NOT NULL          | Thiết bị    |
| sync_status       | TEXT NOT NULL          | PENDING/... |
| idempotency_key   | TEXT UNIQUE NOT NULL   | Chống trùng |
| sap_id            | TEXT                   | Khóa SAP    |
| created_at_utc    | INTEGER NOT NULL       | Tạo         |
| synced_at_utc     | INTEGER                | Đồng bộ     |

## 8.9 Bảng GhiNhanSanLuong

| **Cột**         | **Kiểu/ràng buộc**     | **Ý nghĩa** |
| --------------- | ---------------------- | ----------- |
| id              | TEXT PK                | UUID        |
| phan_cong_id    | TEXT FK NOT NULL       | Phân công   |
| quantity        | REAL NOT NULL CHECK >0 | Hoàn thành  |
| business_date   | TEXT NOT NULL          | Ngày SX     |
| shift_id        | TEXT FK NOT NULL       | Ca          |
| note            | TEXT                   | Ghi chú     |
| created_by      | TEXT NOT NULL          | MaNV        |
| occurred_at_utc | INTEGER NOT NULL       | Sự kiện     |
| device_id       | TEXT NOT NULL          | Thiết bị    |
| sync_status     | TEXT NOT NULL          | PENDING/... |
| idempotency_key | TEXT UNIQUE NOT NULL   | Chống trùng |
| sap_id          | TEXT                   | Khóa SAP    |
| created_at_utc  | INTEGER NOT NULL       | Tạo         |
| synced_at_utc   | INTEGER                | Đồng bộ     |

## 8.10 Bảng ThuHoiPhanCong

| **Cột**         | **Kiểu/ràng buộc**     | **Ý nghĩa**        |
| --------------- | ---------------------- | ------------------ |
| id              | TEXT PK                | UUID               |
| phan_cong_id    | TEXT FK NOT NULL       | Phân công          |
| quantity        | REAL NOT NULL CHECK >0 | Thu hồi            |
| reason_code     | TEXT NOT NULL          | Lý do              |
| note            | TEXT                   | Bắt buộc nếu OTHER |
| business_date   | TEXT NOT NULL          | Ngày SX            |
| shift_id        | TEXT FK NOT NULL       | Ca                 |
| created_by      | TEXT NOT NULL          | Supervisor         |
| occurred_at_utc | INTEGER NOT NULL       | Sự kiện            |
| device_id       | TEXT NOT NULL          | Thiết bị           |
| sync_status     | TEXT NOT NULL          | PENDING/...        |
| idempotency_key | TEXT UNIQUE NOT NULL   | Chống trùng        |
| sap_id          | TEXT                   | Khóa SAP           |
| created_at_utc  | INTEGER NOT NULL       | Tạo                |
| synced_at_utc   | INTEGER                | Đồng bộ            |

## 8.11 Bảng SyncQueue

| **Cột**            | **Kiểu/ràng buộc** | **Ý nghĩa**   |
| ------------------ | ------------------ | ------------- |
| id                 | TEXT PK            | UUID          |
| entity_type        | TEXT NOT NULL      | Loại entity   |
| entity_id          | TEXT NOT NULL      | ID bản ghi    |
| action             | TEXT NOT NULL      | CREATE/UPDATE |
| priority           | INTEGER NOT NULL   | Thứ tự        |
| retry_count        | INTEGER NOT NULL   | Số retry      |
| next_retry_at_utc  | INTEGER            | Lần tiếp      |
| last_error_code    | TEXT               | Mã lỗi        |
| last_error_message | TEXT               | Lỗi đã lọc    |
| created_at_utc     | INTEGER NOT NULL   | Tạo           |
| updated_at_utc     | INTEGER NOT NULL   | Cập nhật      |

## 8.12 Bảng AuditLog

| **Cột**            | **Kiểu/ràng buộc** | **Ý nghĩa**     |
| ------------------ | ------------------ | --------------- |
| id                 | TEXT PK            | UUID            |
| event_type         | TEXT NOT NULL      | LOGIN/VIEW/...  |
| actor_id           | TEXT NOT NULL      | Người làm       |
| target_employee_id | TEXT               | Người bị xem    |
| entity_type        | TEXT               | Loại entity     |
| entity_id          | TEXT               | ID entity       |
| business_date      | TEXT               | Ngày SX         |
| shift_id           | TEXT               | Ca              |
| occurred_at_utc    | INTEGER NOT NULL   | Sự kiện         |
| device_id          | TEXT NOT NULL      | Thiết bị        |
| metadata_json      | TEXT               | Metadata đã lọc |

## 8.13 Index và constraint

| **Đối tượng** | **Đề xuất**                                                                         |
| ------------- | ----------------------------------------------------------------------------------- |
| Unique        | NhanVien.ma_nv; DonHang.ma_don_hang; idempotency_key ở mọi giao dịch.               |
| Query ngày    | GhiNhan(phan_cong_id, business_date, shift_id); Audit(actor_id, occurred_at_utc).   |
| Dashboard     | PhanCong(nhan_vien_id,status); PhanCong(to_id,business_date); ThuHoi(phan_cong_id). |
| Sync          | SyncQueue(priority,next_retry_at_utc); mọi entity(sync_status).                     |
| FK            | RESTRICT xóa master đang được tham chiếu; không cascade xóa giao dịch.              |
| Check         | quantity>0; enum hợp lệ; OTHER yêu cầu note ở domain/API.                           |
| Atomicity     | Giao dịch nghiệp vụ + SyncQueue + AuditLog cùng một DB transaction.                 |

## 8.14 Query tổng hợp chuẩn

completed = SUM(GhiNhanSanLuong.quantity WHERE phan_cong_id = ?)  
recalled = SUM(ThuHoiPhanCong.quantity WHERE phan_cong_id = ?)  
effective = PhanCong.assigned_quantity - recalled  
remaining = effective - completed  
periodCompleted = SUM(quantity WHERE business_date BETWEEN ? AND ? AND shift_id IN (...))

## 8.15 Migration và retention

Drift schemaVersion tăng tuần tự; mọi migration có test từ phiên bản cũ. Master/cache đã đồng bộ có thể dọn theo chính sách một ngày, nhưng giao dịch PENDING/SYNCING/FAILED, AuditLog liên quan và dữ liệu cần đối soát không được tự xóa. Sau SYNCED, dữ liệu lịch sử cũ được tải lại từ SAP khi tra cứu.

# 9\. Repository, API và SAP

## 9.1 Hợp đồng nghiệp vụ

findEmployeeByCode(maNV)  
getSessionPermissions()  
getSupervisorScope(supervisorId)  
createAssignment(command)  
recordProduction(command)  
recallAssignment(command)  
getEmployeeSummary(employeeId, businessDateRange, shiftIds)  
watchEmployeeLogs(employeeId, filter)  
syncPending()

## 9.2 API logical endpoints

| **Method** | **Endpoint**                | **Quyền**             | **Idempotency** |
| ---------- | --------------------------- | --------------------- | --------------- |
| GET        | /employees/{maNV}           | Theo phiên/phạm vi    | Không           |
| GET        | /me/permissions             | Đã xác thực           | Không           |
| GET        | /supervisors/me/scope       | Supervisor            | Không           |
| GET        | /assignments?employeeId=... | Own/Team View         | Không           |
| POST       | /assignments                | ASSIGN_QUANTITY       | Có              |
| POST       | /production-entries         | RECORD_OWN_PRODUCTION | Có              |
| POST       | /assignment-recalls         | RECALL_ASSIGNMENT     | Có              |
| GET        | /employees/{id}/summary     | Own/Team View         | Không           |
| GET        | /employees/{id}/logs        | Own/History View      | Không           |

## 9.3 Payload ghi nhận

{  
"idempotencyKey": "uuid",  
"assignmentId": "...",  
"quantity": 100,  
"businessDate": "2026-08-05",  
"shiftId": "NIGHT",  
"occurredAtUtc": "2026-08-05T19:00:00Z",  
"deviceId": "..."  
}

## 9.4 Quy tắc server

| **Rule**       | **Yêu cầu**                                                                               |
| -------------- | ----------------------------------------------------------------------------------------- |
| Authorization  | Kiểm tra permission và SupervisorScope trên server, không tin UI.                         |
| Concurrency    | Tính remaining trong transaction/lock hoặc optimistic version.                            |
| Idempotency    | Cùng key trả lại kết quả cũ, không tạo bản ghi mới.                                       |
| Overproduction | Từ chối nếu quantity > remaining tại thời điểm commit.                                    |
| Recall         | Từ chối nếu quantity > maxRecall.                                                         |
| Clock          | Server lưu timestamp chuẩn; vẫn giữ occurredAt từ thiết bị và đánh dấu lệch giờ nếu cần.  |
| Error contract | Mã lỗi ổn định: OUT_OF_SCOPE, OVER_REMAINING, ASSIGNMENT_CLOSED, DUPLICATE, AUTH_EXPIRED. |

## 9.5 Mapping OData/RAP dự kiến

| **Domain**        | **Entity SAP dự kiến**         | **Operation** |
| ----------------- | ------------------------------ | ------------- |
| Employee          | Employee/Worker                | Read          |
| Permission/Scope  | UserAuthorization/TeamScope    | Read          |
| Order             | ProductionOrder/SalesOrderItem | Read          |
| Assignment        | ZC_ProductionAssignment        | Read/Create   |
| Production entry  | ZC_ProductionEntry             | Create action |
| Assignment recall | ZC_AssignmentRecall            | Create action |
| Summary           | ZC_EmployeeProductionSummary   | Read          |
| Log               | ZC_ProductionLog               | Read          |

Tên entity cuối cùng do đội SAP chốt. Flutter chỉ phụ thuộc repository/domain model; mapping nằm trong SapRemoteDataSource.

# 10\. Bảo mật, audit và vận hành

| **Hạng mục**    | **Yêu cầu**                                                                            |
| --------------- | -------------------------------------------------------------------------------------- |
| Token           | Lưu secure storage; không lưu trong SQLite/log.                                        |
| Thiết bị chung  | Timeout, đổi người, xóa state nhạy cảm, không preload dữ liệu người trước.             |
| Mã badge        | Không coi là bằng chứng quyền Supervisor.                                              |
| Log kỹ thuật    | Ẩn token/PII/payload nhạy cảm; có correlation ID.                                      |
| Audit nghiệp vụ | Ghi login, đổi người, xem nhân viên, tạo phân công, ghi nhận, thu hồi, retry thủ công. |
| Encryption      | Cân nhắc SQLCipher nếu chính sách doanh nghiệp yêu cầu.                                |
| Screen capture  | Cân nhắc chặn tại màn hình nhạy cảm theo chính sách.                                   |
| Clock tampering | So sánh giờ thiết bị với server; log độ lệch.                                          |
| Data purge      | Chỉ purge dữ liệu SYNCED theo retention; không purge pending/failed.                   |

# 11\. Kiểm thử

| **Nhóm**   | **Ca kiểm thử bắt buộc**                                                                 |
| ---------- | ---------------------------------------------------------------------------------------- |
| Domain     | Công thức giao hiệu lực/còn lại/maxRecall; xuyên ngày; ca đêm; UoM.                      |
| Permission | Công nhân không xem người khác; Supervisor ngoài scope bị chặn; permission thay đổi.     |
| Database   | Migration; transaction atomic; index/query; app kill giữa save.                          |
| Production | Ghi nhiều lần; đúng bằng remaining; vượt remaining; double tap; hai thiết bị cạnh tranh. |
| Recall     | Một phần; nhiều lần; hết phần; vượt max; OTHER thiếu note.                               |
| Offline    | Mất mạng 1 ngày; app restart; retry; duplicate; failed business rule.                    |
| Scanner    | PDA Enter; ký tự nhanh/chậm; camera; mã trùng; focus sau dialog.                         |
| Shift      | 22:00-06:00; biên 00:00; đổi ca; timezone.                                               |
| UX         | Loading/empty/error/offline; chữ lớn; găng tay; màn hình PDA.                            |
| SAP UAT    | Role/scope thật; OData errors; idempotency; đối soát totals.                             |

## 11.1 Tiêu chí nghiệm thu MVP

| **#** | **Tiêu chí**                                                        |
| ----- | ------------------------------------------------------------------- |
| 1     | Công nhân chỉ xem và ghi nhận trên phân công của chính mình.        |
| 2     | Supervisor chỉ quản lý các tổ SAP cấp phạm vi.                      |
| 3     | Supervisor tạo được phân công và công nhân nhìn thấy sau lưu local. |
| 4     | Phân công OPEN tiếp tục sang ngày hôm sau.                          |
| 5     | Nhật ký phân loại đúng businessDate và ca qua 0 giờ.                |
| 6     | Không thể ghi nhận vượt số còn lại ở UI, DB/domain và API.          |
| 7     | Thu hồi chỉ áp dụng phần chưa làm và không sửa dữ liệu gốc.         |
| 8     | Tổng giao hiệu lực, hoàn thành, thu hồi và còn lại khớp giao dịch.  |
| 9     | Dữ liệu được lưu khi offline và đồng bộ lại không trùng.            |
| 10    | Pending quá 24 giờ vẫn còn và được cảnh báo.                        |
| 11    | Thiết bị dùng chung không lộ dữ liệu người trước.                   |
| 12    | PDA và camera quét ổn định trên thiết bị thực.                      |
| 13    | Lọc hôm nay/hôm qua/7 ngày/khoảng ngày/ca cho kết quả đúng.         |
| 14    | Audit ghi được actor, target, entity, thời gian và device.          |
| 15    | SAP permission chi tiết điều khiển đúng nút và API.                 |

# 12\. Lộ trình phát triển

| **Phase**          | **Thời lượng dự kiến** | **Phạm vi**                                                         | **Đầu ra**                                  |
| ------------------ | ---------------------- | ------------------------------------------------------------------- | ------------------------------------------- |
| 0\. Discovery & UX | 1-2 tuần               | Chốt UoM, ca, quyền, wireframe, mã quét, dữ liệu mock.              | Prototype + data dictionary + rule catalog. |
| 1\. MVP local      | 4-6 tuần               | Auth mock, Drift, phân công, ghi nhận, thu hồi, lịch sử, ca, audit. | APK offline + test domain/DB.               |
| 2\. Scanner & Sync | 2-4 tuần               | Camera, PDA, mock API, queue, retry, idempotency, sync UI.          | APK pilot kỹ thuật.                         |
| 3\. SAP OData/RAP  | 3-6 tuần               | Auth/quyền/scope, entity mapping, validation server, đối soát.      | Bản UAT tích hợp.                           |
| 4\. Pilot nhà máy  | 2-3 tuần               | Một Supervisor và vài tổ; đo thao tác, lỗi, sync.                   | Báo cáo pilot + backlog.                    |
| 5\. Production     | Theo rollout           | Hardening, monitoring, tài liệu, đào tạo, phát hành nội bộ.         | Go-live và vận hành.                        |

## 12.1 Definition of Done cho mỗi feature

| **Điều kiện** | **Mô tả**                                              |
| ------------- | ------------------------------------------------------ |
| Nghiệp vụ     | Rule được code và có unit test.                        |
| UI            | Đủ loading/empty/error/offline/unauthorized.           |
| Database      | Migration, index, transaction và query test.           |
| Security      | Permission kiểm tra ở controller/repository và server. |
| Audit         | Hành động trọng yếu tạo log.                           |
| Sync          | Có idempotency, retry và trạng thái.                   |
| Accessibility | Vùng chạm, contrast, semantics, scale text.            |
| Device QA     | Chạy trên ít nhất một PDA mục tiêu và Android phone.   |
| Documentation | API/schema/changelog cập nhật.                         |

# 13\. Các quyết định còn cần doanh nghiệp chốt

| **Quyết định**                    | **Khuyến nghị mặc định**                                        |
| --------------------------------- | --------------------------------------------------------------- |
| Đơn vị tính có số lẻ?             | Cấu hình precision theo UoM; "cái" dùng số nguyên.              |
| Timeout thiết bị chung?           | 2-5 phút không hoạt động tùy khu vực.                           |
| Supervisor có ghi thay công nhân? | Tắt mặc định; nếu bật dùng permission riêng và audit.           |
| Thu hồi cần phê duyệt?            | MVP một bước nếu Supervisor có quyền; SAP có thể thêm workflow. |
| Cache master data                 | Giữ đủ để offline một ngày; refresh khi mở phiên/có mạng.       |
| Pending quá lâu                   | Cảnh báo sau 24 giờ; không xóa.                                 |
| Phạm vi lịch sử local             | Một ngày đã sync; dữ liệu cũ truy vấn SAP.                      |
| Định dạng barcode                 | Ưu tiên Code128/QR chứa MaNV; chốt bằng mẫu thật.               |

# 14\. Phụ lục - DDL SQLite tham chiếu

CREATE TABLE production_entries (  
id TEXT PRIMARY KEY,  
assignment_id TEXT NOT NULL REFERENCES assignments(id),  
quantity REAL NOT NULL CHECK(quantity > 0),  
business_date TEXT NOT NULL,  
shift_id TEXT NOT NULL REFERENCES shifts(id),  
created_by TEXT NOT NULL,  
occurred_at_utc INTEGER NOT NULL,  
device_id TEXT NOT NULL,  
sync_status TEXT NOT NULL,  
idempotency_key TEXT NOT NULL UNIQUE,  
sap_id TEXT, created_at_utc INTEGER NOT NULL, synced_at_utc INTEGER  
);  
<br/>CREATE INDEX idx_prod_assignment_date  
ON production_entries(assignment_id, business_date, shift_id);

DDL đầy đủ nên được sinh và quản lý bằng Drift migration. Đoạn trên là chuẩn tham chiếu cho review kỹ thuật, không thay thế migration source code.