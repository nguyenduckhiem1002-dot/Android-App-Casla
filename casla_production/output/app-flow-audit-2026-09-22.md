# Rà soát flow và validation — 22/09/2026

## Phạm vi và bằng chứng

Rà mã Flutter và chạy toàn bộ unit/widget/integration tests trong repository. Đã đọc router, shell, phân công, xác nhận, thu hồi riêng, phản hồi mutation, truy vấn phạm vi và đồng bộ. Đây không phải kiểm thử trực tiếp APK trên thiết bị hoặc giao dịch với SAP thật. Trang HTML demo không được dùng làm bằng chứng cho hành vi mobile.

Lần đầu: 393 test qua, 5 thất bại. Sau sửa: **399 test qua**. Log: `audit-test-results.log` tại gốc dự án. Số test tăng do bổ sung hồi quy SAP từ chối.

## Đã sửa trong lượt này

| Mức | Phát hiện | Thay đổi và kiểm chứng |
| --- | --- | --- |
| Cao | Gửi hoàn thành + thu hồi vẫn gọi thu hồi khi hoàn thành bị SAP từ chối; có thể báo đã lưu cho giao dịch lỗi | Dừng trước bước thu hồi, hiện lỗi, giữ form cho lỗi nghiệp vụ. Test xác nhận số lần gọi thu hồi bằng 0, giữ số đã nhập. Nếu phần hoàn thành đã lưu nhưng thu hồi bị từ chối thì báo kết quả từng phần và đóng draft để tránh gửi trùng phần hoàn thành. |
| Cao | Mở route Xác nhận độc lập gây `No Material widget found` ở ô tìm kiếm | Thêm Material tại màn chọn; widget test mở standalone và quét được mà không ném lỗi. |
| Vừa | Không tìm thấy việc vẫn chuyển qua lịch sử công nhân | Kiểm tra số dư history của công nhân trước khi chuyển; không còn việc thì giữ màn chọn, báo rõ và làm mới danh sách. Test xác nhận không chuyển route. |
| Vừa | Scope thay đổi lúc chờ tải vẫn có thể mở kết quả của scope cũ | Chụp scope lúc bắt đầu, so lại trước điều hướng. Đã review code; chưa có widget test riêng cho race này. |
| Vừa | Vừa mở form đã báo đỏ dù chưa nhập | Không hiển thị lỗi nhập liệu khi form trống; nút xác nhận vẫn disabled theo validation. Test Back và mở lại form kiểm tra không còn cảnh báo lúc mới vào. |

Hai test scanner thất bại vì nhãn đã đổi thành “Nhập mã thủ công”; đã cập nhật expectation, giữ kiểm tra một nút và vị trí nút. Test phân công còn dùng giờ máy thật và trạng thái ca `X` trong khi contract app dùng `A`: đã tiêm đồng hồ cố định cho test và sửa fixture. Không nới validation giờ ca trong production.

## Flow sau rà soát

- Đăng nhập → đổi mật khẩu bắt buộc nếu có → thiết lập ca nếu thiếu → trang chính. Không nên bỏ các bước bắt buộc này.
- Xác nhận → chọn/quét nhân viên → mở form ngay khi xác định được công đoạn → xác minh → loading giữ trên form → kết quả.
- Không còn việc: ở lại màn chọn. Back từ form trực tiếp: về màn trước một lần, không lộ trang lịch sử phân công.
- Nhiều công đoạn: vẫn cần bước chọn công đoạn. Hiện app dùng màn hoạt động nhân viên cho bước này; đây là ứng viên thay bằng danh sách công đoạn gọn, không được tự bỏ rồi chọn tùy ý.
- Đồng bộ: test hiện có bao phủ phân loại lỗi, retry, phạm vi hàng đợi, popup lỗi và mất mạng. Chưa kiểm thử gesture vuốt/undo trên PDA thật trong lượt này.

## Còn cần xử lý / kiểm chứng

1. **Thu hồi riêng (S09)**: nút Back và Back hệ thống chưa khóa lúc gửi; sau receipt bị từ chối vẫn đi đến `context.pop()`. Người dùng có thể mất ngữ cảnh/số vừa nhập. Cần đưa về cùng pattern loading + popup + giữ draft như S08, kèm widget test với request đang chờ và SAP rejected.
2. **Popup dùng chung**: `showMutationFeedback` hard-code tiêu đề “Phân công…” dù có caller là xác nhận/thu hồi. Nên truyền tên thao tác hoặc dùng “Giao dịch…”, cùng test cho từng caller.
3. **Nhiều phân công cùng một công đoạn**: `directConfirmationAssignment` chọn bản mới nhất. Số dư form là số dư bản đó, không nhất thiết bằng tổng công đoạn. Cần kiểm chứng contract SAP và fixture nhiều lần giao trước khi quyết định gộp; không tự cộng rồi ghi vào một assignment.
4. **Cache history và dữ liệu local**: picker hợp nhất hai nguồn, trong khi báo cáo SAP có thể cũ và có dữ liệu thiếu WorkID. Cần kiểm thử tình huống vừa hoàn tất offline, cache SAP còn số dư, và WorkID rỗng để tránh nhân viên xuất hiện lại. Lượt sửa trước chưa đủ bằng chứng để kết luận toàn bộ các trường hợp này đã được chặn.
5. **Thiết bị thực**: cần chạy bản APK mới với keyboard mở, cỡ chữ lớn, xoay ngang, mất mạng lúc gửi, ca qua đêm và máy quét PDA. Widget tests không chứng minh hoạt động camera/hardware scanner hoặc SAP production.

## Kết luận phạm vi

Các lỗi đã sửa có bằng chứng tự động; các mục còn lại là kết quả audit, không được tính là đã khắc phục. Không xóa các màn tổng quan/lịch sử phục vụ tra cứu chỉ vì chúng không cần trong luồng nhập nhanh.
