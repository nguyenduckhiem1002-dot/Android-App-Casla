# Dev release nội bộ

```powershell
$env:JAVA_TOOL_OPTIONS='-Djdk.net.unixdomain.tmpdir=G:\Android\casla_production\build\java-tmp'
New-Item -ItemType Directory -Path build/java-tmp -Force | Out-Null
flutter build apk --release --flavor dev --dart-define-from-file=.env --build-number=3
```

Output: `build/app/outputs/flutter-apk/app-dev-release.apk`.

- App launcher: **Casla Dev TEST**; package có suffix `.dev`, dữ liệu riêng với bản production/debug production. Cần đăng nhập lại, không tự chuyển queue cũ sang.
- Release AOT, ký bằng Android debug keystore **chỉ ở dev flavor**, không phải chữ ký phát hành chính thức. Giữ cùng keystore cho các lần cập nhật bản test.
- Dev release cho phép Basic Auth từ `.env`, nhưng vẫn yêu cầu HTTPS. Credential có thể bị trích xuất từ APK; chỉ phân phối nội bộ cho người/thiết bị được phép, không đăng APK công khai. Nên dùng tài khoản SAP test hạn chế quyền và thu hồi sau pilot.
- `.dev` không làm SAP thành môi trường giả: endpoint vẫn lấy từ `.env`, các action ghi có thể thay đổi dữ liệu SAP thật.
- Production, staging và release không xác định flavor vẫn loại Basic credential và yêu cầu gateway. Production vẫn phải qua `verifyCaslaSigning` và dùng khóa ký chính thức.
- AGP đưa `preProductionReleaseBuild` vào cả graph dev release, nên guard không được gắn vào lifecycle task dùng chung này. Các task production release còn lại vẫn phụ thuộc guard.

Không dùng `-x verifyCaslaSigning` hoặc thay tên transport thành gateway khi chưa có gateway thật.
