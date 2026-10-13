# Quét mã — hành vi hiện tại

## Bản này: chuyển sang luồng laser-first

Ghép chọn lọc phần QR từ nhánh `claude/ui-review-qr-code-f3f904` tại commit
`4dc249a5844b6d17a3e330aca52d1c93a2cc8a05` ngày 11/09/2026. Các sửa lịch sử,
router và đổi mật khẩu của repo chính được giữ nguyên. Khi ghép đã giữ lại
`bo_phan`, nhận JSON công nhân không phụ thuộc danh mục, chia sẻ một kênh native
giữa các màn hình và sửa nút phụ trên form để không tràn màn PDA.

Thay đổi lớn nhất: **đầu đọc luôn lắng nghe ngay trên form**. Không còn phải mở màn hình quét riêng rồi mới bóp cò.

### Bắt mã

- Hai đường bắt mã chạy song song: **broadcast theo hãng** (CipherLab, Zebra DataWedge, Honeywell/Intermec, Newland, Urovo, Sunmi) và **keyboard wedge**. Wedge hoạt động khi thiết bị được cấu hình xuất mã như bàn phím; cần kiểm tra chế độ thực tế trên PDA.
- Bỏ hoàn toàn điều kiện `Build.MANUFACTURER`/`Build.MODEL` chứa "cipherlab"/"RS38". Việc dò máy giờ chỉ là *gợi ý* để chọn giao diện; kỹ thuật viên ép được chế độ (Tự động / Luôn dùng đầu đọc / Luôn dùng camera) trong màn Tài khoản.
- Camera vẫn chạy song song với đầu đọc: đang mở camera mà bóp cò thì vẫn nhận mã.
- Wedge tự nhường khi con trỏ đang ở ô nhập liệu — mã sẽ vào đúng ô đó, đúng như thói quen dùng wedge.

### Định tuyến mã theo nội dung

- S07 tự phân loại mã vừa quét: mã công đoạn điền vào ô Sản phẩm, thẻ công nhân điền vào ô Công nhân. Quét thứ tự nào trước cũng được.
- Thứ tự thử là `OperationQrParser` trước, `WorkerQrParser` sau — vì parser công nhân có nhánh chấp nhận chuỗi trần, hỏi nó trước sẽ nuốt mất mã công đoạn.
- S10 nhận thẻ công nhân và mở màn hình phân công của người đó. Màn tổng quan S06 giữ nguyên trong lần ghép này.

### Phản hồi và tốc độ

- Bỏ độ trễ cứng 600ms sau mỗi lần quét. Chỉ khi bị từ chối mới có khoảng dừng, và chỉ ở đường camera (để camera không đọc lại đúng nhãn đó liên tục).
- Cửa sổ chống trùng còn 400ms và tính theo mốc thời gian của chính lần quét, không theo lúc handler chạy. Quét lại cùng một thẻ có chủ ý vẫn được chấp nhận.
- Có tiếng và rung phân biệt: nhận được / bị từ chối / trùng lặp. Quản lý không cần nhìn màn hình.
- Thanh trạng thái trên đầu form cho biết đầu đọc có đang sống không và đã quét được bao nhiêu mã.

### Chống quét nhầm

- QR JSON công nhân hợp lệ được nhận trực tiếp, không cần có sẵn trong danh mục. Chỉ mã chuỗi trần chưa biết mới hỏi xác nhận nhằm tránh quét nhầm mã thùng hàng.
- Payload có dạng mã vạch bán lẻ (EAN-8/UPC-A/EAN-13/ITF-14) hiện cảnh báo mạnh hơn: "Có thể quét nhầm mã hàng".
- Công nhân đã có trong danh mục thì đi thẳng, không thêm ma sát.

## Giữ nguyên từ bản trước

- Hai màn quét công nhân S07/S10 nhận mã, tên và `bo_phan` từ QR, kiểm tra ValidFrom/ValidTo theo ngày trên thiết bị (bao gồm hai ngày đầu/cuối).
- Không so phạm vi tổ, không gọi API SAP để xác minh QR. Công nhân mới lưu cục bộ với quyền và tổ rỗng; không tạo tài khoản đăng nhập SAP.
- QR sai cấu trúc/ngày lỗi vẫn bị từ chối. QR legacy không có ngày giữ hành vi không giới hạn thời hạn.
- QR công đoạn đủ khóa hợp lệ được lưu trực tiếp, giữ payload, ProductionOrder và Operation phục vụ đồng bộ.
- Ô số lượng giao và thông báo thành công dùng `uom` của công đoạn, không ghi cố định "cái".
- Tab Xác nhận bị gỡ scanner khi không được chọn; handler cũng kiểm tra TickerMode và route hiện hành trước khi nhận sự kiện.
- Mật khẩu công nhân và backend authorization khi ghi SAP giữ nguyên. QR tự sửa có thể qua bước chọn nếu đúng định dạng/ngày; đây là cơ chế trust QR được yêu cầu, không phải QR có chữ ký số.

## Log chẩn đoán tại hiện trường

Khi PDA "không ăn laze" mà không có máy dev cắm cạnh, hiện trường tự lấy log được:

- **Account → Đầu đọc mã vạch → Xóa log quét**, quét thử vài lần, rồi **Sao chép log quét**. Dán log đó cho support.
- Log chứa tên sự kiện, thời điểm, độ dài và thông tin định danh ứng dụng gửi nếu Android cung cấp. Không chứa nội dung QR hay mật khẩu; bộ test kiểm tra giới hạn và dữ liệu có thể đi vào log.
- Bộ đệm giữ tối đa 120 sự kiện mỗi lớp (Kotlin native + Dart), vòng tròn — không phình vô hạn khi để app chạy cả ca.
- Native còn đếm `nativeKeyDownEvents`/`nativeMultipleKeyEvents` — phím Android thực sự nhận được trong lúc có màn hình đang lắng nghe quét. Tăng mà không thấy `wedgeBurst` phía Flutter → đầu đọc có gõ nhưng Flutter không bắt (kiểm tra focus/`HardwareKeyboard`), không tăng → phím chưa tới được Activity (đầu đọc chưa bật keystroke output, hoặc trigger chưa gán).
- Chi tiết cách đọc từng mã sự kiện: `android/SCANNER_SECURITY.md`.

## Tình trạng kiểm thử

- `flutter analyze` sạch; 311 test Dart pass.
- Test Kotlin (`ScannerBroadcastPolicyTest`, `ScannerDiagnosticLogTest`) **chưa chạy được cục bộ** — Gradle trên máy dev báo `Unable to establish loopback connection` (lỗi môi trường/mạng cục bộ, không phải thiếu wrapper — wrapper đã có). CI chạy `:app:testProductionDebugUnitTest`.
- Người dùng báo bản worktree đã quét được trên PDA. Bản ghép vào repo chính vẫn cần kiểm thử lại trên thiết bị thật; danh sách ở `android/SCANNER_SECURITY.md`.
