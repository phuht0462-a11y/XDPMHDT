# Cá nhân hóa & Lưu trữ ngoại tuyến — bàn giao bổ sung

## Phạm vi thay đổi

- Xử lý tuần tự các thao tác cache/outbox để hai lần thêm yêu thích hoặc ghi lượt xem đồng thời không ghi đè dữ liệu của nhau.
- Lưu ý định thêm/xóa yêu thích trước khi gửi HTTP; lỗi 408/429/5xx giữ thao tác để thử lại. Lỗi yêu cầu 4xx khác trả thất bại và phục hồi trạng thái trước đó.
- `isFavorite` ưu tiên thao tác ngoại tuyến đang chờ gửi, tránh hiển thị lại trạng thái cũ từ server.
- Đồng bộ tự động khi mở ứng dụng, đăng nhập, quay lại foreground và mỗi 30 giây khi ứng dụng ở foreground. Không phải tác vụ chạy khi hệ điều hành đã đóng ứng dụng.
- Chặn yêu cầu đồng bộ tiếp theo nếu tài khoản đã thay đổi; cache và outbox vẫn tách theo userId.
- Không đưa trùng một clientEventId vào outbox; giữ nguyên payload và ID đã chờ gửi. Batch tối đa 100 sự kiện; batch thất bại còn nguyên để thử lại.
- Cảnh báo khi danh sách yêu thích còn thay đổi đang chờ đồng bộ.

Không thay đổi schema, API backend hoặc cấu hình Auth/Gateway/Analytics.

## Kiểm tra đã thực hiện cho thay đổi này

- Dart formatter đọc và định dạng thành công các file Dart mới/sửa trong personalization và test.
- `git diff --check`: đạt.
- **Chưa chạy Flutter test, analyzer hoặc build ứng dụng.** Khởi tạo Flutter SDK trong môi trường sửa mã bị kiểm tra tự động chặn do công cụ cố truy cập địa chỉ metadata máy chủ. Không coi formatter là kiểm thử chức năng.

Các minh chứng người dùng đã cung cấp trước thay đổi Flutter: 8 test backend đạt; health UP; sự kiện artifact.updated xóa cache Redis; Favorites/Visits qua Gateway và Analytics tăng đúng 3 lượt đều PASS. Đây là kết quả trước đó trên máy người dùng, không phải một lần chạy lại trên bản commit này.

## Kiểm thử tự động cần chạy trước khi hợp nhất

Từ thư mục `Interface`, với Flutter tương thích `pubspec.yaml`:

```powershell
flutter pub get
flutter analyze lib/features/personalization test/features/personalization
flutter test test/features/personalization/personalization_offline_test.dart test/personalization_screens_test.dart test/visit_history_grouping_test.dart
flutter build web --dart-define=API_BASE_URL=http://localhost:8080
```

File test mới có 8 tình huống: thêm đồng thời khi mất mạng; ưu tiên ý định ADD/REMOVE; gửi lại ý định cuối cùng và chống đồng bộ chồng; phân biệt 503/400; ghi lượt xem đồng thời và giữ ID; batch 205 sự kiện với lỗi giữa chừng; đổi tài khoản khi đang gửi; cách ly cache giữa tài khoản. Dùng HTTP mock và SharedPreferences mock; không cần tài khoản thật hoặc DB.

## Nghiệm thu giao diện trên Windows

1. Giữ Docker và các service Auth, Gateway, Content, Personalization, Analytics chạy. Chạy `flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080` trong `Interface`.
2. Đăng nhập tài khoản thử, tải Favorites và Visit History để có cache.
3. Trong Chrome DevTools, Network chọn Offline (tắt Wi-Fi không chặn được localhost). Thêm rồi bỏ yêu thích một hiện vật, thêm hiện vật khác và ghi lượt xem; mở lại danh sách để kiểm tra dữ liệu cục bộ.
4. Chọn No throttling. Khi ứng dụng đang mở, chờ ít nhất 30 giây rồi làm mới danh sách. Kiểm tra API và DB nhận đúng ý định cuối cùng; gửi lại không tăng số lượt với cùng clientEventId.
5. Đổi tài khoản: không được thấy cache hoặc gửi outbox của tài khoản trước. Đăng nhập lại tài khoản cũ để tiếp tục đồng bộ dữ liệu của tài khoản đó.
6. Kiểm tra đóng/mở lại ứng dụng khi còn hàng đợi. Web cache thuộc origin: giữ cùng hostname và cổng khi thử lại phiên web.

## Giới hạn còn cần theo dõi

- Cần thực hiện nghiệm thu UI ở trên; chưa có minh chứng chạy ứng dụng sau thay đổi.
- Việc refresh JWT dùng AuthHttpClient hiện có; bài test mock không thay cho kiểm thử đăng nhập/refresh trên server.
- Lỗi nghiệp vụ lâu dài trong outbox (ví dụ hiện vật đã ngừng hoạt động) được giữ lại, không tự xóa dữ liệu; có thể cần xử lý riêng thay vì chờ retry.
- Danh sách hiện tại chỉ tải trang đầu tối đa 100 mục theo hành vi có sẵn.
