# Quét QR — build 4

## Sửa tiếp ở build 5

- S07 dùng AdaptiveBarcodeScannerView cho cả QR công nhân và công đoạn: đầu đọc PDA được ưu tiên, camera là fallback.
- Tab Xác nhận bị gỡ scanner khi không được chọn; handler hardware cũng kiểm tra TickerMode và route hiện hành trước khi nhận sự kiện. Tránh tab ẩn mở nhầm chi tiết sản lượng.
- Ô số lượng giao và thông báo thành công dùng `uom` của công đoạn, không ghi cố định “cái”; không làm tròn mất phần thập phân trong thông báo.
- Test tái hiện tab ẩn nhận QR thất bại trước sửa, pass sau sửa. Test form xác nhận công nhân quay lại form và công đoạn KG hiển thị KG. Toàn bộ 212 tests pass; analyze sạch; chưa kiểm thử vật lý PDA.

- Hai màn quét công nhân S07/S10 nhận mã và tên từ QR, kiểm tra ValidFrom/ValidTo theo ngày trên thiết bị (bao gồm hai ngày đầu/cuối).
- Không yêu cầu công nhân tồn tại trong danh mục, không so phạm vi tổ, không gọi API SAP để xác minh QR. Công nhân mới được lưu cục bộ với quyền và tổ rỗng; không tạo tài khoản đăng nhập SAP.
- QR sai cấu trúc/ngày lỗi vẫn bị từ chối. QR legacy không có ngày giữ hành vi không giới hạn thời hạn; không suy ra thời hạn từ dữ liệu SAP cache.
- QR công đoạn đủ khóa hợp lệ được lưu trực tiếp, không tra danh mục để chấp nhận. Giữ payload, ProductionOrder và Operation phục vụ đồng bộ. Mã sản phẩm đơn lẻ không chứa đủ khóa công đoạn không thay thế QR công đoạn; chọn thủ công vẫn có danh sách riêng.
- Danh sách chọn thủ công và màn tổng quan giữ phạm vi hiện có. Tải lịch sử sau khi mở chi tiết không phải API kiểm tra QR.
- Mật khẩu công nhân và backend authorization khi ghi SAP giữ nguyên. QR tự sửa có thể qua bước chọn nếu đúng định dạng/ngày; đây là cơ chế trust QR được yêu cầu, không phải QR có chữ ký số.

Kiểm tra: flutter analyze sạch; 210 flutter tests pass. Chưa xác minh scanner trên PDA thật.
