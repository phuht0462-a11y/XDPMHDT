# Personalization – phần SRS và báo cáo tuần 7 của Phú

Người phụ trách: **Huỳnh Thiên Phú**. Phạm vi: Favorites, Visit History, Redis cache và đồng bộ ngoại tuyến. Tài liệu này mô tả bản thay đổi tuần 7; trạng thái nghiệm thu nằm trong [bảng kiểm thử](../testing/personalization-w7.md). Đây là phần bàn giao để Bảo ghép vào SRS/báo cáo, không thay thế báo cáo toàn nhóm.

## 1. Đoạn mô tả dùng cho báo cáo

Personalization-service chạy ở cổng 8085, quản lý dữ liệu yêu thích và lịch sử tham quan trong schema `personalization_db`. Ứng dụng gọi API qua Gateway cổng 8080 bằng Bearer JWT. Gateway xác thực, loại bỏ các header `X-User-*` do client gửi và gắn danh tính đã xác thực; service lấy người dùng bằng `CurrentUser.requireUserId()`. Service sở hữu bảng `likes` và `visits`; chỉ lưu mã người dùng và mã hiện vật, không JOIN hoặc ánh xạ entity sang schema của service khác. Tên, ảnh và địa điểm hiện vật được lấy qua Content-service, có Redis cache trong 10 phút.

Khi mạng không ổn định, ứng dụng lưu thao tác vào hàng đợi trên thiết bị theo từng tài khoản trước khi gửi HTTP. Lượt tham quan giữ nguyên `clientEventId` và thời điểm ghi nhận khi gửi lại. Máy chủ dùng ràng buộc duy nhất `(user_id, client_event_id)` và kiểm tra bản ghi đã có để chống ghi lặp; yêu thích dùng khóa chính `(user_id, artifact_id)`. Ứng dụng chỉ xóa mục chờ sau khi nhận phản hồi thành công, thử đồng bộ khi đăng nhập, trở lại foreground và mỗi 30 giây khi đang hoạt động. Đồng bộ lượt tham quan chia thành các lô tối đa 100 sự kiện. Các thao tác local được tuần tự hóa nhằm tránh hai thao tác đọc–sửa–ghi làm mất dữ liệu của nhau.

Khi Redis không sẵn sàng, service gọi Content-service để lấy metadata. Khi Content-service cũng không trả được metadata, API đọc vẫn giữ bản ghi cá nhân từ MySQL và dùng tên dự phòng `Hiện vật #<id>`, các metadata chưa có để `null`. Nhánh ghi mới vẫn kiểm tra hiện vật ACTIVE; nếu không thể xác minh thì trả lỗi tạm thời để ứng dụng giữ thao tác chờ, không báo đã ghi thành công. Chỉ mục `(user_id, detected_at)` phục vụ truy vấn lịch sử theo người dùng và sắp xếp thời gian, có migration riêng cho database đang sử dụng.

## 2. Yêu cầu và điều kiện nghiệm thu

| Mã nội bộ tài liệu | Yêu cầu | Điều kiện nghiệm thu |
|---|---|---|
| PER-W7-01 | Lưu thao tác trước khi gửi | Có outbox khi gửi thất bại; không sinh lại UUID khi thử lại |
| PER-W7-02 | Ba beacon và hai yêu thích khi offline | Khi kết nối lại có đủ 3 lượt và 2 mục, gửi lại không làm tăng số bản ghi |
| PER-W7-03 | Ưu tiên ý định mới nhất | ADD rồi REMOVE cùng hiện vật chỉ đồng bộ REMOVE; nút yêu thích không bị GET cũ đảo trạng thái |
| PER-W7-04 | Chịu lỗi dịch vụ phụ trợ | Redis ngừng vẫn đọc/ghi được khi Content hoạt động; Content ngừng vẫn đọc dữ liệu cá nhân |
| PER-W7-05 | Tối ưu truy vấn lịch sử | Có index và số đo trước/sau trên cùng tập dữ liệu, cùng câu SQL |
| PER-W7-06 | Cách ly tài khoản | Không gửi hàng đợi tài khoản cũ dưới phiên tài khoản mới |

Các mã PER-W7 chỉ dùng để đối chiếu tài liệu, **không phải mã Jira**. File phân công chưa chỉ rõ mã XDPMHDT của Phú; cần xác nhận trước khi đặt tên nhánh/PR chính thức.

## 3. Hợp đồng dữ liệu

- `likes`: khóa ghép `user_id, artifact_id`; `saved_at` là thời điểm lưu trên máy chủ.
- `visits`: `id`, `user_id`, `artifact_id`, `detected_at`, `duration_seconds`, `client_event_id`, `source`. `duration_seconds=null` là chưa đo được, không tự đổi thành 0.
- `detectedAt` từ app là thời điểm có múi giờ; service chuyển sang `Asia/Ho_Chi_Minh` để lưu `LocalDateTime`.
- `VisitRecorded`: envelope có `eventId`, `type`, `version`, `occurredAt`, `data`. **Data chỉ có ba trường `visitId`, `artifactId`, `detectedAt`**, đúng code và PR #63; không dùng mô tả payload bảy trường cũ.
- `ArtifactUpdated`: nhận `data.artifactId` để xóa `artifact:summary:<id>`; đánh dấu event đã xử lý trong Redis 7 ngày.
- Trường `_local` của outbox là metadata hiển thị nội bộ ứng dụng, được loại bỏ trước khi gửi API.

## 4. Khi nào dùng Redis, RabbitMQ và NiFi?

| Thành phần | Vai trò trong dự án | Không thay thế |
|---|---|---|
| MySQL | Nguồn dữ liệu chính của yêu thích và lượt tham quan, giao dịch và ràng buộc duy nhất | Không dùng cache làm nguồn dữ liệu cá nhân duy nhất |
| SharedPreferences | Lưu cache và thao tác chưa đồng bộ trên thiết bị, tách theo tài khoản | Không phải Redis; không phải hàng đợi bảo đảm bền vững tuyệt đối khi thiết bị mất điện |
| Redis | Cache metadata hiện vật; đánh dấu sự kiện đã xử lý | Không dùng làm nơi duy nhất lưu lượt tham quan/yêu thích |
| RabbitMQ | Chuyển sự kiện gần thời gian thực giữa các service: `visit.recorded`, `artifact.updated` | Không thay NiFi trong việc tổng hợp kho dữ liệu định kỳ |
| NiFi | Luồng ETL định kỳ vào analytics, phục vụ dữ liệu phân tích/báo cáo | Không phải API tương tác và không phải cache app |

`publishAfterCommit` chỉ phát sau khi giao dịch thành công. Phần personalization hiện **chưa có producer outbox**: broker hỏng đúng lúc phát có thể làm thiếu sự kiện Analytics, dù lượt tham quan đã lưu trong MySQL. Không được trình bày hệ thống là exactly-once toàn tuyến hoặc bảo đảm không mất sự kiện trong mọi tình huống. NiFi và cơ chế đối soát của analytics là trách nhiệm phối hợp với Tuấn/Bảo, không tự sửa module của các bạn.

## 5. Câu hỏi bảo vệ và ý trả lời

1. **Mất phản hồi sau khi DB đã ghi thì sao?** App chưa nhận xác nhận nên giữ outbox; gửi lại cùng UUID. Máy chủ nhận biết bản ghi đã có và không ghi/phát sự kiện lại cho lượt đó.
2. **Tại sao khóa gồm cả user_id?** UUID nhận từ client nằm trong phạm vi một người dùng; ràng buộc bảo vệ dữ liệu theo tài khoản. Gateway quyết định danh tính, client không tự chọn user ID.
3. **Vì sao không dùng Redis để lưu lịch sử chính?** Cache có thể hết hạn, bị xóa hoặc ngừng. Lịch sử/yêu thích cần dữ liệu bền vững và ràng buộc giao dịch trong MySQL.
4. **Content ngừng vẫn hiện tên được không?** Có cache thì dùng cache; không có thì chỉ giữ dữ liệu cá nhân với tên dự phòng. Không bịa tên/ảnh, không cho ghi mới với hiện vật chưa xác minh.
5. **Index giúp gì?** Tiền tố user_id lọc theo người dùng, detected_at hỗ trợ thứ tự thời gian. Đổi lại index chiếm dung lượng và tăng chi phí ghi; phải đo cả truy vấn trang và COUNT, không chỉ nhìn thời gian một lần.
6. **Tại sao không JOIN users/artifacts?** Mỗi service sở hữu schema riêng; dùng ID logic và API để giảm phụ thuộc, tránh schema của thành viên khác làm hỏng service.
7. **Redis chết có mất yêu thích không?** Không, yêu thích nằm trong MySQL; app còn cache/outbox của tài khoản. Metadata đọc qua Content có thể chậm hơn.
8. **App đóng hẳn có tự đồng bộ nền không?** Không có bảo đảm chạy nền khi hệ điều hành đóng app. Hàng đợi được thử lại khi mở/resume/đăng nhập; chu kỳ 30 giây chỉ khi foreground.
9. **Xóa app/xóa dữ liệu thiết bị khi chưa đồng bộ?** Outbox local có thể mất; không hứa khôi phục từ server những thao tác server chưa từng nhận.
10. **Phân biệt kiểm duyệt và personalization?** Feedback-service của Tường quản lý quy trình duyệt đánh giá. Personalization chỉ quản lý lượt xem/yêu thích, không tự thay đổi trạng thái kiểm duyệt hiện vật/đánh giá.

## 6. Bàn giao và phối hợp

- Bảo: dùng đoạn mô tả mục 1 và bảng công nghệ mục 4; review hai dòng tích hợp `PersonalizationSync` trong `Interface/lib/main.dart`.
- Tường: review index thuộc `personalization_db` và chạy migration không xóa volume.
- Ân: nhập kết quả thật từ bảng test, giữ rõ mục chưa chạy; không chuyển NOT RUN thành PASS.
- Xuân Anh/Khoa: phối hợp kiểm thử trên app với 3 beacon thật hoặc simulator và Content-service thật.
- Phú: luyện câu hỏi mục 5; việc tập bảo vệ với cả nhóm phải do người tham gia thực hiện, tài liệu này không xác nhận đã tập.
