# Rà soát UI và performance — 11/09/2026

Phạm vi: các màn hình Flutter đang được router/shell sử dụng, màn camera và các bộ chọn dùng chung. Đây là rà soát mã nguồn, chưa phải benchmark trên TC22. Các nguy cơ overflow nêu dưới đây cần kiểm thử theo kích thước, dữ liệu và text scale; không coi là lỗi đã tái hiện. Không thay đổi mã ứng dụng trong lần rà soát này.

## Ưu tiên xử lý

1. **Tổng quan:** tách trạng thái tiến độ khỏi trạng thái đồng bộ; tối ưu ghép dữ liệu trước khi lọc; làm mới cache danh mục đúng lúc.
2. **Chi tiết công nhân / Đồng bộ / Chi tiết phân công:** chuyển danh sách giao dịch dài sang dựng từng dòng khi cần, tránh dựng cả danh sách trong một lần.
3. **Thu hồi / ghi nhận:** thống nhất hiển thị số lượng đến độ chính xác nghiệp vụ; tránh làm tròn khiến người dùng hiểu sai phần còn lại.
4. **Camera / nhập tay Xác nhận / đổi mật khẩu bắt buộc:** kiểm thử chiều cao thấp, bàn phím và chữ lớn; bổ sung bố cục thích ứng.
5. Chuẩn hóa cỡ chữ, nút, thuật ngữ và font trước khi trang trí thêm.

## Từng màn hình

### 1. Đăng nhập — S02B

- UI: `s02b_account_login_screen.dart:143` đã cuộn được và giới hạn rộng 420. Tuy nhiên padding ngoài 20 cộng padding card 24 làm ô nhập hẹp trên PDA. Thu gọn phần logo/giới thiệu khi mở bàn phím; dùng nhãn “Tài khoản” phù hợp cả công nhân lẫn quản lý thay vì hint “mã quản lý / username”.
- Performance: chưa thấy điểm nóng render đáng ưu tiên trong form ngắn. Đo riêng thời gian xác thực SAP trước khi tối ưu widget.
- Mức ưu tiên: vừa.

### 2. Đổi mật khẩu bắt buộc

- UI: `mandatory_password_change_screen.dart:50` dùng Center → Padding → Column không có cuộn. Có nguy cơ thiếu chiều cao khi chữ lớn/màn ngang. Dùng vùng cuộn có chiều cao tối thiểu, giữ nút thao tác trong vùng truy cập được.
- Performance: màn tĩnh, không cần tối ưu riêng; giữ nguyên cơ chế bắt buộc đổi mật khẩu.
- Mức ưu tiên: vừa.

### 3. Thiết lập ca

- UI: `supervisor_shift_setup_screen.dart:269` cắt tên Work Center về một dòng; danh mục dài khó tìm vì dropdown không có tìm kiếm. Dùng bộ chọn có tìm kiếm khi danh mục lớn, hiển thị mã + tên đủ rõ. Nút “Tiếp tục” ở cuối nội dung có thể đổi thành “Lưu thay đổi” khi mở từ Tài khoản.
- Performance: `_loadGeneration` đã chống kết quả tải cũ ghi đè lựa chọn mới (`:53`). Không có cơ sở kết luận thiếu cơ chế này. Có thể tái sử dụng danh mục ca theo nhà máy/ngày ở tầng controller nếu đo được tải lặp.
- Mức ưu tiên: vừa.

### 4. Tổng quan — S06

- UI: `_workerStatusBadge` (`s06_supervisor_overview_screen.dart:2223`) trả lỗi/chờ đồng bộ trước tiến độ. Vì vậy “Đang làm / Hoàn thành 1 phần / Hoàn thành toàn bộ” có thể bị che. Nên có một nhãn tiến độ và một biểu tượng đồng bộ độc lập.
- UI: tên công nhân và StatusChip dài nằm chung hàng (`:1448`); tên mất nhiều không gian sau khi tăng độ dài nhãn. Đưa tiến độ xuống hàng dưới, ưu tiên tên và số lượng. Nhiều chữ 11–11.5 px nhỏ trên PDA.
- Performance: trong vòng lặp từng công nhân (`:1149`), code tìm trong danh sách nhân viên và lọc toàn bộ giao dịch SAP (`:1167`). Chi phí tăng theo W×(E+T). Tạo map nhân viên theo mã/id và nhóm giao dịch theo worker một lần.
- Performance: gõ tìm kiếm gọi setState (`:891`), làm lại khối ghép, cộng KPI và sắp xếp. Tách dữ liệu tổng hợp khỏi truy vấn tìm kiếm; chỉ lọc danh sách đã chuẩn hóa. Debounce là bổ sung, không thay thế việc giảm tính toán.
- Performance: `_ensureHistoryEmployees` (`:128`) await ghi SQLite từng công nhân trước khi trả kết quả. Dùng batch/transaction và hạn chế ghi lại dữ liệu không đổi nếu benchmark cho thấy đây là điểm chậm.
- Cache: `_employeesFor` (`:270`) chỉ đổi Future khi phạm vi tổ đổi; `_refresh` chỉ refresh lịch sử. Danh mục có thể cũ khi cùng tổ nhưng nhân viên thay đổi. Cần invalidation theo thay đổi danh mục, không đơn thuần thêm cache.
- Điểm tốt: danh sách chính dùng builder; các stream/future đã được lưu, không phải cứ build là gọi SAP mới.
- Mức ưu tiên: cao.

### 5. Chi tiết công nhân — S06B

- UI: nhiều lớp KPI, phân công, ghi nhận và thu hồi trên cùng màn. Nên có bộ lọc “Phân công / Ghi nhận / Thu hồi”, dùng một kiểu hàng giao dịch và tăng cỡ chữ metadata từ 10.5–11.5 px.
- UI: mã lệnh + công đoạn và badge nằm cùng Row (`s06b_employee_daily_detail_screen.dart:1031`); cần co giãn/xuống hàng với mã dài.
- Performance: `ListView(children: ...)` (`:879`) chứa các vòng `for` tạo card cho từng giao dịch (`:1020` và các phần sau). Dựng trước toàn bộ widget khi kỳ dài. Dùng CustomScrollView + SliverList.builder, chỉ dựng nhóm đang xem; phân trang nếu API hỗ trợ.
- Mức ưu tiên: cao.

### 6. Tạo phân công — S07

- UI: ô hiện chữ “Chọn công nhân” nhưng chạm thân ô chỉ chọn đích quét; danh sách nằm trong camera → nhập thủ công. Đây là độ lệch giữa nhãn và hành vi. Đề xuất nhãn chờ trung tính “Chưa chọn công nhân”, giữ viền cho ô đang nhận quét; có thể đổi nhãn thủ công trong màn con thành “Chọn từ danh sách”. Không tự đưa nút ngoài trở lại vì người dùng đã yêu cầu bỏ.
- UI: trường ghi chú và tùy chọn giữ sản phẩm có thể gom thành phần tùy chọn thu gọn. Giữ sản phẩm, công nhân, số lượng là trọng tâm.
- Performance: `_pickWorker` đọc SQLite theo thao tác (`:238`), không gọi SAP mỗi lần mở. Chưa có bằng chứng cần thêm RAM cache. Bộ chọn dùng ListView.separated, đã dựng dòng theo nhu cầu.
- Điểm cần hiểu đúng: QR công nhân mới lưu không có tổ nên không xuất hiện trong danh sách lọc theo tổ; đó là chính sách phạm vi, không phải cache mất dữ liệu.
- Mức ưu tiên: vừa.

### 7. Chi tiết phân công / nhập sản lượng — S08

- UI: lời nhắc tối đa dùng `toStringAsFixed(2)` (`s08_assignment_detail_screen.dart:100`) trong khi NumPad hỗ trợ 3 số lẻ. Với mức còn lại 0.005, lời nhắc có thể hiện 0.01 nhưng nhập 0.01 bị từ chối. Dùng formatter số lượng thống nhất.
- UI: số lớn 42 px và đơn vị nằm trong Row không co giãn (`:110`); cần test số 6 chữ số, dấu thập phân và text scale lớn. Giữ bàn phím số nhưng co vùng số thích ứng.
- Performance: lịch sử dùng ListView.separated shrinkWrap trong phần cuộn (`:455`); danh sách lớn làm tăng chi phí dựng/layout. Chuyển sang sliver hoặc giới hạn trang.
- Mức ưu tiên: cao về số liệu, vừa về bố cục.

### 8. Thu hồi — S09

- UI: preview “Giao hiệu lực / Còn lại sau thu hồi” dùng `toStringAsFixed(0)` (`s09_recall_screen.dart:403`, `:424`), trong khi ô cho nhập số lẻ. Ví dụ 0.4 và 0.2 đều có thể hiện 0 → 0. Hiển thị đúng số lẻ và đơn vị là việc cần sửa trước màu sắc.
- UI: hai hàng preview không có Flexible cho giá trị dài; cân nhắc bố cục dọc ở màn hẹp. Danh sách lý do có thể giữ RadioListTile vì dễ chạm, chưa cần thay thành dropdown.
- Performance: setState theo mỗi phím làm rebuild cả màn; có thể giới hạn rebuild ở phần preview. Danh sách lý do nhỏ nên đây chưa phải điểm nóng được chứng minh.
- Mức ưu tiên: cao về số liệu.

### 9. Xác nhận / đầu đọc — S10

- UI: panel đầu đọc mới đã gọn, nên giữ. Phần nhập tay của S10 thực tế là nhập mã (`s10_confirm_scan_screen.dart:79`), khác với chọn danh sách ở S07; nên đặt nhãn đúng chức năng.
- UI: bottom sheet nhập mã dùng Padding + Column với viewInsets, không cuộn (`:101`); hàng tiêu đề cũng chưa Flexible (`:117`). Cần kiểm thử bàn phím/chữ lớn và cho cuộn.
- Performance: đã có chặn xử lý đồng thời, chống trùng và quản lý scanner theo route/tab. Không nên tối ưu bằng cách bỏ các chốt này.
- Mức ưu tiên: vừa.

### 10. Camera dùng chung

- UI: `qr_scanner_view.dart:205` vẫn dùng Column + Spacer, logo lớn và khung quét cố định; thiết kế này khác panel đầu đọc vừa sửa. Có nguy cơ thiếu chiều cao với subtitle dài/nút chuyển chế độ. Dùng LayoutBuilder để chia vùng header, viewfinder và thao tác.
- UI: dòng “GHI NHẬN SẢN LƯỢNG” xuất hiện cả khi chọn công nhân/công đoạn; nên dùng tiêu đề tác vụ. Thống nhất “Nhập bằng tay” / “Nhập mã thủ công” theo đúng chức năng; chuyển mã thiết bị/phiên bản sang Tài khoản.
- Performance: camera đã start/stop theo lifecycle và route, có hỗ trợ reduced motion. Chỉ đo FPS/nhiệt/pin trên TC22 trước khi đổi cấu hình camera; không suy ra chậm từ việc có animation.
- Mức ưu tiên: cao về bố cục thích ứng, vừa về hình thức.

### 11. Đồng bộ — S12

- UI: trạng thái lỗi toàn màn yêu cầu mở lại nhưng không có nút thử lại (`s12_sync_screen.dart:355`). Thêm retry tại chỗ; hiển thị nội dung người vận hành cần làm trước, giấu chi tiết kỹ thuật trong panel.
- Performance: đã phân trang bằng cursor (`:97`), nhưng list shrinkWrap bên trong SingleChildScrollView (`:378`, `:440`) làm mất lợi ích dựng dòng theo viewport khi tải thêm nhiều trang. Đổi sang một CustomScrollView.
- Trải nghiệm cập nhật: `_replaceFirstPage` (`:82`) thay toàn bộ `_feedItems` bằng trang đầu. Khi stream cập nhật trong lúc xem trang sau, các dòng đã tải thêm biến mất. Cần merge/refresh có bảo toàn vị trí hoặc thông báo có dữ liệu mới.
- Mức ưu tiên: cao.

### 12. Lịch sử công nhân — W01

- UI: bốn tab thời gian cùng hàng, chiều cao 48 (`w01_history_screen.dart:447`, `:553`); test chữ lớn và nhãn xuống dòng. Nút “Đổi” có padding dọc 4 (`:496`) nên tăng vùng chạm tối thiểu 48.
- Performance: đã dùng CustomScrollView + SliverList và giữ dữ liệu cũ khi refresh lỗi (`:410`, `:753`). Giữ cấu trúc này; chưa thấy lý do viết lại hoặc thêm cache màn hình.
- Mức ưu tiên: thấp–vừa.

### 13. Tài khoản — S13

- UI: thẻ hồ sơ và nhóm thông tin lặp tên/mã/phạm vi; thu gọn hồ sơ, chia “Thông tin / Ca làm việc / Đầu đọc / Bảo mật”. Nhãn quyền 10.5 px (`s13_account_screen.dart:208`) quá nhỏ so với chuẩn đang dùng.
- Performance: màn ngắn, chủ yếu tĩnh; ưu tiên đọc dễ và tránh rebuild do các notify không liên quan, không thêm cache riêng.
- Mức ưu tiên: vừa.

### 14. Thanh điều hướng / shell

- UI: shell quản lý ghi đè nhãn tab xuống 11 px (`supervisor_shell.dart:112`), thấp hơn theme 12. Thống nhất và test đủ 5 tab với cỡ chữ lớn.
- Performance: đã lazy-mount tab và gỡ S10 khi ẩn (`:85`). Tuy nhiên tab đã mở khác vẫn sống trong IndexedStack; TickerMode tắt animation, không tự dừng subscription dữ liệu. Đo SQL/rebuild khi chuyển tab; nếu cần, tạm dừng phần tổng hợp UI của tab ẩn nhưng vẫn giữ sync nghiệp vụ.
- Mức ưu tiên: vừa; cần profile trước khi thay vòng đời tab.

## Vấn đề dùng chung

- `pubspec.yaml:72` phần khai báo fonts đang comment, trong code có Manrope/Inter. Không thể coi tên font trong TextStyle là font đã đóng gói. Chọn một font hỗ trợ tiếng Việt, đóng gói và áp dụng ở theme; hoặc chủ ý dùng font hệ thống và bỏ tên font chưa có.
- Cỡ chữ 10, 10.5, 11, 11.5 xuất hiện ở nhiều màn, trong khi CaslaType.caption đặt 12. Chuyển dần về token, tăng vùng chạm lên tối thiểu 48, giữ số liệu quan trọng lớn hơn metadata.
- Bộ chọn `searchable_picker_sheet.dart` đặt chiều cao 68% màn hình cộng padding bàn phím; nên tính theo vùng còn lại khi IME mở. Danh sách đã lazy, không đánh đồng với các list shrinkWrap dài.
- WorkHistoryRepositoryImpl có cache và map `_inFlight` (`repositories_impl.dart:795` trở đi). Không nên thêm cache rải rác chỉ vì thấy Future/Stream; ưu tiên invalidation và đo số request thực tế.

## Cách kiểm chứng trước khi sửa performance

- Chạy profile trên TC22 với cấu hình dự án: `flutter run --profile --flavor production --dart-define-from-file=.env -d 26057524700233`.
- Dùng dữ liệu thử cùng cấu trúc: 50/200/500 công nhân, 100/1.000/5.000 giao dịch; không dùng số đo từ debug làm kết luận production.
- Đo thời gian mở Tổng quan, phản hồi tìm kiếm, frame build/raster khi cuộn, số lần SQL và mức bộ nhớ sau khi mở các tab.
- UI: kiểm tra 320×480, 360×560 và kích thước thật của TC22; chữ 100%/150%/200%; bàn phím mở; tên/mã dài; số lượng lẻ; offline; đang gửi; lỗi; đã hoàn thành.
- Sửa từng nhóm, đo lại cùng bộ dữ liệu. Chưa có số đo FPS/latency/memory trong báo cáo này.
