# personalization-service — Phú W5

Microservice **Cá nhân hóa & Lưu trữ ngoại tuyến (History, Favorites & Offline Cache)**, cổng **8085**, schema **personalization_db**.

## Nguyên tắc tách service

- Chỉ sở hữu bảng `likes` và `visits` trong `personalization_db`.
- `user_id` và `artifact_id` chỉ là `Long`, **không** `@ManyToOne` sang `users`/`artifacts` vì hai bảng đó thuộc service khác.
- User hiện tại lấy bằng `CurrentUser.requireUserId()` từ `services/common`; client không tự gửi `X-User-Id` qua Gateway.
- Tên/trạng thái/site/thumbnail hiện vật lấy qua REST từ content-service. `CONTENT_SERVICE_URL` có thể trỏ `http://localhost:8083`; khi chạy cùng Backend cũ có thể trỏ `http://localhost:8090`.
- Cache/offline phía app Flutter tiếp tục dùng `Interface/lib/features/personalization/personalization_service.dart`; backend chống ghi trùng bằng `clientEventId`.

## Chạy

```powershell
mvn -q -DskipTests install
mvn -pl services/personalization-service spring-boot:run
```

Swagger: `http://localhost:8085/swagger-ui.html`
Health: `http://localhost:8085/actuator/health`

Khi test tích hợp qua Gateway 8080, đặt:

```powershell
$env:PERSONALIZATION_SERVICE_URL="http://localhost:8085"
```

## API

- `GET /api/me/favorites?page=0&size=20`
- `POST|PUT /api/me/favorites/{artifactId}`
- `DELETE /api/me/favorites/{artifactId}`
- `GET /api/me/favorites/{artifactId}/exists`
- `GET /api/me/visits?page=0&size=20`
- `POST /api/me/visits`
- `POST /api/me/visits/batch`
- `GET /api/admin/visits?from=2026-10-01&to=2026-10-31&siteId=1`
- Redis demo trực tiếp cổng 8085: `/api/cache/demo` (chỉ bật khi `REDIS_DEMO_ENABLED=true`).

## Kiểm tra build

```powershell
mvn -pl services/personalization-service -am test
mvn -pl services/personalization-service -am -DskipTests package
```

## XDPMHDT-48 — Sprint 6 (nhánh từ main mới nhất)

- Lượt tham quan mới (`POST /api/me/visits`) hoặc lượt mới trong batch (`POST /api/me/visits/batch`) được lưu DB trước; sau commit gọi `EventPublisher.publishAfterCommit("visit.recorded", "VisitRecorded", data)`.
- Data đúng hợp đồng với analytics-service của Tuấn: `visitId`, `artifactId`, `detectedAt` (`LocalDateTime`, múi giờ `Asia/Ho_Chi_Minh`).
- Shared `EventsConfig` được import bằng `@Configuration` riêng (`EventsImportConfig`), không sửa thư viện common.
- Subscriber `artifact.updated` xóa `artifact:summary:{id}` (Redis), chống lặp `eventId`, retry 3 lần rồi dead-letter.
- Cache-aside trong `ArtifactClient`: TTL 10 phút, Redis lỗi sẽ gọi content-service.
- Không copy/cherry-pick nhánh cũ bị conflict; PR squash merge, không merge main vào feature branch.

### Kiểm thử và cấu hình

```powershell
mvn -pl services/personalization-service -am test
mvn -pl services/personalization-service -am -DskipTests package
docker compose -f Infra/docker-compose.yml --profile mq up -d
$env:ANALYTICS_SERVICE_URL = "http://localhost:8087"
$env:BEACON_SERVICE_URL = "http://localhost:8084"
```

RabbitMQ: http://localhost:15672. Cần có analytics-service nhận `visit.recorded` để kiểm tra đếm realtime.
Trong RabbitMQ UI, xem queue của analytics, không chỉ exchange (exchange topic không tự giữ tin).
Lưu ý: `publishAfterCommit` không lưu producer outbox để gửi lại khi broker mất kết nối; cần phối hợp Bảo nếu muốn bảo đảm không mất tin.

## Tuần 7 — ổn định personalization

- Outbox Flutter lưu thao tác trước khi gửi; giữ `clientEventId` khi retry, đồng bộ khi mở lại app/đăng nhập và định kỳ lúc app ở foreground.
- Khi Content hoặc Redis lỗi, danh sách cá nhân vẫn giữ bản ghi; thiếu metadata hiển thị `Hiện vật #id`. Thêm mới vẫn cần xác minh hiện vật hợp lệ.
- Chỉ mục lịch sử: `(user_id, detected_at)`. DB đang có dữ liệu dùng `Infra/personalization_w7_indexes.sql`; không xóa volume.
- [Yêu cầu, kiến trúc và câu hỏi bảo vệ](../../Docs/requirements/personalization-w7.md).
- [Kết quả kiểm thử, số đo và các bước nghiệm thu còn lại](../../Docs/testing/personalization-w7.md).
- [Hướng dẫn thao tác offline](../../Docs/testing/personalization-w7.md#thao-tác-trên-app).

Flutter/device chưa được nghiệm thu trên bản thay đổi này. Xem trạng thái từng hạng mục trong báo cáo; không dùng kết quả backend thay cho kiểm thử app.
