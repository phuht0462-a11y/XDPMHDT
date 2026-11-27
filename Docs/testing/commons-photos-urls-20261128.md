# Ảnh thực tế bổ sung cho Smart Heritage (Wikimedia Commons)

Đã chọn 6 ảnh hiện vật/địa điểm từ Wikimedia Commons (xem URL và giấy phép trong `Infra/seed/commons-heritage-photos.json`). Đây là nguồn **tham khảo bổ sung**, không thay thế 18 file demo đang nằm trong Docker.

## Tải về máy Windows

Trong PowerShell tại thư mục gốc repo:

```powershell
powershell -ExecutionPolicy Bypass -File "Infra\seed\download-commons-photos.ps1"
```

Ảnh được tải vào `%USERPROFILE%\Downloads\SmartHeritageCommons` và kèm `CREDITS.md` chứa tên tác giả, nguồn và giấy phép.

**Sau khi tải về:**
1. Mở Web Admin → Hiện vật → chọn từng mã hiện vật tương ứng (`KVC-01`, `BTS-01`, `DM-01`, `DTM-W7`, `DKT-W7`, `CCHN-W7`).
2. Ở trường Ảnh đại diện và/hoặc Hình ảnh của bản dịch, dùng nút tải lên trong Web Admin để lưu ảnh vào Content Service. Không dán URL trang HTML `commons.wikimedia.org/wiki/File:...` vào trường ảnh.
3. Lưu hiện vật và mở `GET /api/artifacts/{id}?lang=vi` để xác nhận `thumbnailUrl` / `imageUrls` là URL media thực hoạt động.
4. Thêm phần nguồn ảnh/giấy phép vào trang giới thiệu hoặc tài liệu nộp nhóm theo `CREDITS.md`.

**Tại sao không khuyến khích dùng trực tiếp URL trên mạng làm nguồn ảnh duy nhất?** Trình duyệt có thể gặp hạn chế CORS/hotlink, nguồn đổi đường dẫn hoặc mạng mất; điều này còn ảnh hưởng kiểm thử **Offline Cache** của nhóm. Nếu cần demo nhanh online thì có thể dán URL `imageUrl` trực tiếp từ JSON vào trường `thumbnailUrl` và `imageUrls`, nhưng triển khai ổn định nên upload vào server của dự án.

**Nhãn tư liệu lịch sử:** `DKT-W7` dùng ảnh điện Kính Thiên 1884–1885 (Charles-Édouard Hocquard); phải ghi rõ **ảnh lịch sử**, không mô tả như hình ảnh hiện trạng nền điện.

**Bản quyền:** Hai ảnh trong bộ là public domain, một CC0 và ba ảnh CC BY/CC BY-SA; ảnh CC yêu cầu ghi công/tài khoản tác giả, liên kết giấy phép và thông tin chỉnh sửa nếu có. Không lấy ảnh Getty Images hoặc nguồn thương mại không rõ quyền sử dụng.

**Liên hệ với lỗi 11 URL cũ:** nhập ảnh mới không tự sửa toàn bộ link `https://example.com/...` trong database cũ. Vẫn cần migration backup `repair-legacy-demo-db.ps1 -Apply`, hoặc thay các trường URL tương ứng qua Web Admin sau khi sao lưu. Audio đa ngôn ngữ là một nhiệm vụ khác, không thể được thay bằng ảnh.
