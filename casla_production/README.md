# casla_production

A new Flutter project.

## Android: chạy đúng bản Tổng quan mới

Trong Android Studio, đặt Additional run args thành
`--flavor production --dart-define-from-file=.env` (file `.env` chỉ ở máy local).
Hoặc chạy từ thư mục project:

```powershell
flutter run --flavor production --dart-define-from-file=.env -d emulator-5554
```

APK để cài thủ công là `build/app/outputs/flutter-apk/app-production-debug.apk`.
Không dùng `build/app/outputs/apk/debug/app-debug.apk`: file đó có thể còn sót từ
build trước khi project có flavors, cùng package nhưng giao diện cũ. Thời gian
cài đặt mới không đồng nghĩa nội dung APK mới.

Nếu Java trên Windows báo `Unable to establish loopback connection`, có thể đặt
thư mục socket tạm riêng cho phiên terminal rồi chạy lại lệnh trên:

```powershell
New-Item -ItemType Directory -Path build/java-tmp -Force | Out-Null
$caslaSocketDir = (Resolve-Path build/java-tmp).Path
$env:JAVA_TOOL_OPTIONS = "$env:JAVA_TOOL_OPTIONS -Djdk.net.unixdomain.tmpdir=$caslaSocketDir"
```

Bộ lọc Tổng quan gồm Tất cả tổ, Hôm nay, Tuần này, Tháng này và Khoảng ngày.
Chọn Khoảng ngày để mở lịch chọn ngày bắt đầu/kết thúc, sau đó bấm ÁP DỤNG.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
