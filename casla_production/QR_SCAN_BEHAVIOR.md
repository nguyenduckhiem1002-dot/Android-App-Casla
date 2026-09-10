# Quét mã — hành vi hiện tại

## Bản này: chuyển sang luồng laser-first

Thay đổi lớn nhất: **đầu đọc luôn lắng nghe ngay trên form**. Không còn phải mở màn hình quét riêng rồi mới bóp cò.

### Bắt mã

- Hai đường bắt mã chạy song song: **broadcast theo hãng** (CipherLab, Zebra DataWedge, Honeywell/Intermec, Newland, Urovo, Sunmi) và **keyboard wedge**. Wedge là mẫu số chung của mọi PDA ở chế độ xuất xưởng, nên máy thuộc hãng chưa khai báo vẫn quét được.
- Bỏ hoàn toàn điều kiện `Build.MANUFACTURER`/`Build.MODEL` chứa "cipherlab"/"RS38". Việc dò máy giờ chỉ là *gợi ý* để chọn giao diện; kỹ thuật viên ép được chế độ (Tự động / Luôn dùng đầu đọc / Luôn dùng camera) trong màn Tài khoản.
- Camera vẫn chạy song song với đầu đọc: đang mở camera mà bóp cò thì vẫn nhận mã.
- Wedge tự nhường khi con trỏ đang ở ô nhập liệu — mã sẽ vào đúng ô đó, đúng như thói quen dùng wedge.

### Định tuyến mã theo nội dung

- S07 tự phân loại mã vừa quét: mã công đoạn điền vào ô Sản phẩm, thẻ công nhân điền vào ô Công nhân. Quét thứ tự nào trước cũng được.
- Thứ tự thử là `OperationQrParser` trước, `WorkerQrParser` sau — vì parser công nhân có nhánh chấp nhận chuỗi trần, hỏi nó trước sẽ nuốt mất mã công đoạn.
- S06 nhận cò trực tiếp: quét thẻ công nhân là mở thẳng chi tiết ngày của người đó.

### Phản hồi và tốc độ

- Bỏ độ trễ cứng 600ms sau mỗi lần quét. Chỉ khi bị từ chối mới có khoảng dừng, và chỉ ở đường camera (để camera không đọc lại đúng nhãn đó liên tục).
- Cửa sổ chống trùng còn 400ms và tính theo mốc thời gian của chính lần quét, không theo lúc handler chạy. Quét lại cùng một thẻ có chủ ý vẫn được chấp nhận.
- Có tiếng và rung phân biệt: nhận được / bị từ chối / trùng lặp. Quản lý không cần nhìn màn hình.
- Thanh trạng thái trên đầu form cho biết đầu đọc có đang sống không và đã quét được bao nhiêu mã.

### Chống quét nhầm

- Mã công nhân **chưa có trong danh mục** giờ phải xác nhận trước khi tạo. Trước đây quét nhầm mã thùng hàng là lặng lẽ sinh ra một công nhân mang tên mã vạch đó.
- Payload có dạng mã vạch bán lẻ (EAN-8/UPC-A/EAN-13/ITF-14) hiện cảnh báo mạnh hơn: "Có thể quét nhầm mã hàng".
- Công nhân đã có trong danh mục thì đi thẳng, không thêm ma sát.

## Giữ nguyên từ bản trước

- Hai màn quét công nhân S07/S10 nhận mã và tên từ QR, kiểm tra ValidFrom/ValidTo theo ngày trên thiết bị (bao gồm hai ngày đầu/cuối).
- Không so phạm vi tổ, không gọi API SAP để xác minh QR. Công nhân mới lưu cục bộ với quyền và tổ rỗng; không tạo tài khoản đăng nhập SAP.
- QR sai cấu trúc/ngày lỗi vẫn bị từ chối. QR legacy không có ngày giữ hành vi không giới hạn thời hạn.
- QR công đoạn đủ khóa hợp lệ được lưu trực tiếp, giữ payload, ProductionOrder và Operation phục vụ đồng bộ.
- Ô số lượng giao và thông báo thành công dùng `uom` của công đoạn, không ghi cố định "cái".
- Tab Xác nhận bị gỡ scanner khi không được chọn; handler cũng kiểm tra TickerMode và route hiện hành trước khi nhận sự kiện.
- Mật khẩu công nhân và backend authorization khi ghi SAP giữ nguyên. QR tự sửa có thể qua bước chọn nếu đúng định dạng/ngày; đây là cơ chế trust QR được yêu cầu, không phải QR có chữ ký số.

## Tình trạng kiểm thử

- `flutter analyze` sạch; 308 test Dart pass.
- Test Kotlin (`ScannerBroadcastPolicyTest`) **chưa chạy được cục bộ** — máy dev không có gradle wrapper (Flutter sinh lúc build). CI chạy `:app:testProductionDebugUnitTest`.
- **Chưa kiểm thử trên PDA thật.** Danh sách việc cần làm trên máy thật ở `android/SCANNER_SECURITY.md`.
