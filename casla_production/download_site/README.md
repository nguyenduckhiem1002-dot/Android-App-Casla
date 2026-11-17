# Trang tải ứng dụng CASLA

Trang web (Next.js, deploy trên Vercel) để người dùng mở link là tải được APK mới
nhất. Phát hành bản mới bằng **một lệnh** ở máy build; trang tự hiện bản mới,
không cần deploy lại.

```
tool\publish_release.cmd
   │  1. flutter build apk --flavor … --dart-define-from-file=.env
   │  2. đọc versionName / versionCode / package thật trong APK (aapt), tính SHA-256
   │  3. tải APK lên Vercel Blob
   │  4. ghi meta/manifest.json (danh sách phiên bản), dọn bản quá cũ
   ▼
Trang web đọc manifest mỗi lần mở  →  nút "Tải về máy" trỏ tới bản mới nhất
```

## Thiết lập một lần

1. **Đưa code lên GitHub**. Gốc repo là thư mục cha của `casla_production`, nên
   trang nằm ở `casla_production/download_site`.
2. **Tạo project trên Vercel**: Add New → Project → chọn repo → đặt
   **Root Directory = `casla_production/download_site`** → Deploy. Framework tự
   nhận là Next.js.
   `vercel.json` đã cấu hình để Vercel chỉ build lại khi thư mục này thay đổi,
   commit code Flutter không làm trang deploy lại.
3. **Tạo Blob store**: trong project → Storage → Create → Blob → chọn kiểu
   **Public** → Connect vào project. Vercel tự thêm biến
   `BLOB_READ_WRITE_TOKEN`. Sau đó Redeploy một lần để trang nhận biến.
   (Nếu tạo store Private thì đặt thêm `BLOB_ACCESS=private` ở cả Vercel và
   `.env.local`.)
4. **Máy phát hành**: chép `.env.example` thành `.env.local` trong thư mục này,
   điền `BLOB_READ_WRITE_TOKEN` (Storage → store → tab `.env.local`) và
   `SITE_URL` (địa chỉ trang, để script in link). File này không được commit.

## Phát hành một bản

Chạy từ gốc project, trong Terminal (Gradle không build được trong sandbox):

```powershell
# Mặc định: flavor production, bản debug, dart-define từ .env
tool\publish_release.cmd --notes "Sửa lỗi đồng bộ\nThêm nút thu hồi"

# Bản staging release, dùng .env.qas
tool\publish_release.cmd --flavor staging --mode release --env-file .env.qas

# Đã build sẵn rồi, chỉ đưa file lên
tool\publish_release.cmd --skip-build
tool\publish_release.cmd --apk build\app\outputs\flutter-apk\app-production-debug.apk

# Xem trước sẽ làm gì, không build, không tải lên
tool\publish_release.cmd --skip-build --dry-run
```

Tất cả tùy chọn: `tool\publish_release.cmd --help`.

- **Số phiên bản** lấy từ chính file APK. Muốn mỗi bản một số build riêng thì
  thêm `--bump` (versionCode = bản đã phát hành gần nhất + 1) hoặc
  `--build-number <n>`; không thêm thì dùng `version:` trong `pubspec.yaml`.
  Lưu ý: máy đã cài build cao hơn sẽ không cài đè được build thấp hơn, kể cả khi
  `flutter run` từ máy dev.
- **Ghi chú** dài hoặc có ký tự đặc biệt (`&`, `|`, `%`): viết vào file rồi dùng
  `--notes-file ghi_chu.txt`, mỗi dòng một ý.
- **Kênh**: mỗi flavor là một kênh trên trang (Chính thức / Thử nghiệm / Phát
  triển). Trang chỉ hiện thanh chọn kênh khi có từ hai kênh trở lên.
- **Dọn bản cũ**: mỗi kênh giữ 5 bản mới nhất, bản cũ hơn bị xóa khỏi store.
  Đổi bằng `--keep <n>`, `--keep 0` là giữ hết.
- Script kiểm tra APK đúng là file vừa build (README gốc đã cảnh báo APK sót từ
  lần build trước); build lỗi thì không có gì được tải lên.

## Link cố định

| Link | Tác dụng |
| --- | --- |
| `/` | Trang tải: bản mới nhất, cách cài, các bản trước |
| `/?kenh=staging` | Mở sẵn kênh staging |
| `/api/download/latest` | Tải ngay bản mới nhất của kênh chính |
| `/api/download/latest?kenh=staging` | Tải ngay bản mới nhất của kênh staging |

Trên máy tính, trang hiện mã QR để máy cầm tay quét và mở trang.

## Cần biết

- **Ai có link cũng tải được.** Trang không yêu cầu đăng nhập và đã chặn công cụ
  tìm kiếm lập chỉ mục, nhưng link lộ ra ngoài thì người ngoài tải được APK.
  APK build từ `.env` mang theo các giá trị dart-define trong đó (địa chỉ SAP,
  tài khoản Basic nếu đang dùng chế độ `basic`).
- **Cùng một chữ ký.** Android chỉ cho cập nhật đè khi APK mới ký cùng khóa với
  bản đang cài. Bản debug ký bằng debug keystore của máy build, nên hãy phát
  hành từ cùng một máy; đổi máy thì người dùng phải gỡ app rồi cài lại.
- **Dung lượng.** Bản debug khoảng 230 MB, bản release khoảng 38 MB. Blob tính
  cả dung lượng lưu và băng thông tải; theo dõi ở Vercel → Storage → Usage.

## Chạy thử trên máy

Không cần token: phát hành vào kho thử `.local-store/` rồi mở trang ở chế độ dev.

```powershell
tool\publish_release.cmd --skip-build --local
cd download_site
npm run dev    # http://localhost:3000
```

## Cấu trúc

| File | Vai trò |
| --- | --- |
| `scripts/release.mjs` | Lệnh phát hành (build, tải lên, manifest, dọn bản cũ) |
| `lib/shared.mjs` | Định dạng manifest, dùng chung cho script và trang |
| `lib/store.ts` | Đọc manifest, lấy link tải (Blob public/private, kho thử) |
| `app/page.tsx` | Trang tải |
| `app/api/download/[id]/route.ts` | Chuyển hướng tới file APK |
