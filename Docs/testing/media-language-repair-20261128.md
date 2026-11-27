# Smart Heritage — khôi phục media và kiểm thử đa ngôn ngữ (28/11/2026)

## 1. Phân biệt ba vấn đề

1. **Ảnh/audio 404**: `Infra/seed/media/` có **18 file** (12 ảnh JPG, 6 audio tiếng Anh WAV). Dữ liệu `content_db` chỉ chứa URL, không chứa nội dung file. Docker mount volume `content_uploads:/app/uploads`, nên khởi động các service **không tự chép** file từ repo vào volume.
2. **Ảnh trống trên trang chủ Flutter**: `Interface/lib/main.dart` trước đây đặt `image: ''` cho hai thẻ demo nên chỉ hiện placeholder dù ảnh của hiện vật có thật. Bản sửa mới lấy thumbnail từ `GET /api/artifacts` bằng `ArtifactListApi.fetchAll()`, giữ placeholder offline khi API không tải được.
3. **Ngôn ngữ**: Backend có `GET /api/languages`, `POST /api/admin/languages` và bản dịch per-artifact. Bản sửa Flutter dùng danh sách ngôn ngữ đang bật từ API. **Chỉ thêm mã ngôn ngữ không sinh ra bản dịch hoặc lời đọc**: muốn có tiếng Pháp/Đức/Nhật cần nhập nội dung dịch chính xác trong Web Admin; API `GET /api/artifacts/{id}?lang=...` sẽ fallback sang Việt khi chưa có.

## 2. Khôi phục media an toàn trên Windows (không xoá database)

Chạy từ thư mục gốc repo trong PowerShell, khi Docker đang chạy:

```powershell
powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1
```

Script xác minh có đủ **18 file**, chạy `docker cp Infra/seed/media/. smart_heritage_content:/app/uploads/`, rồi HTTP HEAD từng file qua `http://localhost:8080/api/media/files/<tên>`. Script cũng kiểm tra `GET /api/languages`, `GET /api/artifacts`, và `GET /api/artifacts/{id}?lang=vi|en`, in số hiện vật, trạng thái fallback và URL audio tiếng Anh.

Kiểm tra lại **không chép dữ liệu**:
```powershell
powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1 -VerifyOnly
```

Kiểm thử bằng trình duyệt: 
- Ảnh: `http://localhost:8080/api/media/files/d464fdca-51b3-4814-a223-734d2931f97e.jpg`
- Audio tiếng Anh: `http://localhost:8080/api/media/files/0dd6f7ac-f296-4176-b0a9-749787d863e3.wav`
- Ngôn ngữ: `http://localhost:8080/api/languages`
- Bản Việt: `http://localhost:8080/api/artifacts/1?lang=vi`
- Bản Anh: `http://localhost:8080/api/artifacts/1?lang=en`

Nếu 18/18 HEAD đạt nhưng ảnh cũ trong Flutter vẫn không hiện, kiểm tra **URL trả về trong API**, mở F12 → Network/Console và xác minh CORS/mixed content/cache. Trên Android Emulator, client chuyển các đường dẫn media `/api/media/files/` sang origin cấu hình `10.0.2.2:8080` bằng `_mediaUrl`.

## 3. Vá MySQL cũ còn `example.com` (phát hiện thực tế 27/11)

Trường hợp `repair-demo-media.ps1` báo **18/18 HTTP OK** nhưng vẫn có 11 URL `https://example.com/...` trả **404**, chứng tỏ file đã ở trong upload volume, còn các bản ghi của `Infra/db/03_content.sql` cũ vẫn đang nằm trong MySQL. Chạy lại `docker cp` không thể thay các liên kết trong database.

**Bản vá dành riêng cho database demo cũ** (không phải seeding lại):

```powershell
# Từ repo root, sau khi đã lấy nhánh fix mới nhất:
powershell -ExecutionPolicy Bypass -File Infra\seed\repair-legacy-demo-db.ps1
# Xem output preview, chỉ áp dụng nếu các mã KVC-01, BTS-01, DM-01 là demo cũ:
powershell -ExecutionPolicy Bypass -File Infra\seed\repair-legacy-demo-db.ps1 -Apply
```

Chế độ `-Apply` trước tiên dump nguyên database `content_db` bằng `mysqldump` từ container MySQL vào `%USERPROFILE%\SmartHeritageBackups\content_db-before-legacy-fix-<timestamp>.sql`. Nếu dump/copy không thành công thì **không chạy SQL**. Bản vá:

- Chỉ thay chính xác ảnh thumbnail, `image_urls`, `media_resources.file_url` và audio cũ `example.com` của ba mã hiện vật `KVC-01`, `BTS-01`, `DM-01`.
- Giữ nguyên URL ảnh/audio do người dùng tự tải lên.
- Thay 2 audio mẫu EN bằng WAV có thật, bổ sung EN cho Đoan Môn **chỉ khi thiếu**, tránh tạo bản dịch trùng.
- Gỡ **đúng một hàng VIDEO placeholder `https://example.com/media/kvc.mp4`** vì seed không có file video này. Không xóa file media thật.
- Loại bỏ liên kết mp3 VI mẫu không tồn tại (`audio_url=NULL`). Chưa thể phát tiếng Việt cho đến khi có file thuyết minh VI thật.
- Không thay ID hiện vật, không xóa di tích, tài khoản, Favorites, History, dữ liệu tự nhập hay Docker volumes.

Chờ khoảng **120 giây** cho cache Content Service hết hạn trước khi kiểm tra API. Xác minh:

```powershell
powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1 -VerifyOnly
```

**Không tự áp dụng khi dữ liệu khác demo gốc** hoặc khi còn các link lạ không khớp mẫu, vì bản vá không tự sửa nội dung tùy ý. Kết quả cuối phải có `HTTP media verification: 18/18`, URL lỗi trong DB giảm về 0 (đối với dữ liệu demo gốc), và EN audio URL hợp lệ. `flutter test` không thay thế kiểm thử âm thanh thủ công trên trình duyệt.

## 4. Lưu ý dữ liệu demo/SQL

- `Infra/db/09_demo_seed.sql` được Docker MySQL tự chạy **khi volume MySQL mới và trống**. Volume cũ sẽ không tự cập nhật nội dung của script sau `git pull`.
- Nếu API hiện vật không có đủ 6 hiện vật / 12 bản Việt–Anh theo seed, cần kiểm tra dữ liệu MySQL và thực hiện **migration có backup**, không chạy trực tiếp file `09_demo_seed.sql` trên dữ liệu dùng chung vì file có `DELETE FROM media_resources`, `DELETE FROM artifact_contents`, `DELETE FROM artifacts`.
- **Tuyệt đối không chạy `docker compose down -v`** hay `docker volume prune` nhằm sửa ảnh; có thể xóa Visit History, Favorites, tài khoản demo và upload volume.
- Nếu URL trong DB trỏ tới `content-service:8083` (host Docker nội bộ) thay vì Gateway, cần sửa các bản ghi URL theo kế hoạch migration có backup; `PUBLIC_BASE_URL` chỉ điều chỉnh URL cho **upload mới**, không tự đổi các URL cũ trong DB.
- Tài khoản admin có thể upload media mới từ `WebAdmin/src/pages/artifacts.html`, nhấn `Tải lên` ở trường tương ứng. Lưu lại hiện vật và kiểm tra ảnh/audio sau khi upload.

## 5. Cách xác minh đa ngôn ngữ

1. Mở `http://localhost:8080/api/languages` và xác định ngôn ngữ đang `active=true` (ban đầu `vi`, `en`).
2. Web Admin → **Hiện vật** → chọn một hiện vật → bản dịch Việt/Anh → kiểm tra tiêu đề, mô tả, `imageUrls` và `audioUrl`. Trong Flutter chọn English ở màn chi tiết, API phải phản hồi `requestedLanguage=en`, `languageCode=en`, `fallback=false` nếu đã nhập bản Anh.
3. Muốn thêm Pháp `fr`: trong Web Admin phần ngôn ngữ thêm `fr`/Français và bật `active`; mở **từng hiện vật** để thêm bản dịch `languageCode=fr` với nội dung thật. Sau đó màn chi tiết Flutter (sau khi merge bản sửa và chạy lại app) sẽ tự hiển thị `Français (fr)`.
4. Nếu chưa có bản Pháp, API phải trả `fallback=true`, `languageCode=vi`; không coi là đã dịch. **UI toàn ứng dụng** hiện chưa được bản địa hóa đầy đủ sang nhiều ngôn ngữ, thay đổi này chỉ hỗ trợ **nội dung hiện vật trong màn chi tiết**.
5. Bản demo chỉ có **audio tiếng Anh**, không có audio tiếng Việt hoặc ngôn ngữ khác. Muốn âm thanh theo mỗi ngôn ngữ, cần tạo/thu thuyết minh đúng nội dung, upload `.wav` hoặc `.mp3` và gán `audioUrl` cho bản dịch tương ứng. Không sử dụng audio tiếng Anh giả làm tiếng Việt.

## 6. Trạng thái bàn giao

- Các thay đổi mã nguồn đang ở **nhánh riêng**, chưa được merge vào `main` và chưa tự động xuất hiện trên máy Windows sau `git pull`.
- Bước khôi phục media có thể chạy ngay từ repo nếu tải script qua nhánh/PR, hoặc chạy thủ công `docker cp` như mục 2.
- Cần chạy `flutter test`, `flutter analyze` và kiểm thử thủ công trên Edge/Android Emulator sau khi tích hợp; chỉ đánh dấu PASS với bằng chứng thực tế.
