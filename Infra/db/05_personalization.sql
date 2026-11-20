-- =====================================================================
--  personalization_db - personalization-service (Phú, cổng 8085, tách ở tuần 5)
--  Script: Tường - Sprint 4
--  Bảng: visits (lịch sử tham quan), likes (yêu thích)
--  - user_id, artifact_id KHÔNG còn khóa ngoại (users ở auth_db, artifacts ở content_db).
--    Entity dùng cột Long userId, Long artifactId; userId lấy từ header X-User-Id do Gateway gắn.
--  - Id user (1..4) và id hiện vật (1..3) giữ nguyên như auth_db, content_db.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS personalization_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE personalization_db;
SET NAMES utf8mb4;

-- Entity: VisitHistory (Phú)
CREATE TABLE IF NOT EXISTS visits (
    id               BIGINT      NOT NULL AUTO_INCREMENT,
    user_id          BIGINT      NOT NULL,             -- id trong auth_db.users (không FK)
    artifact_id      BIGINT      NOT NULL,             -- id trong content_db.artifacts (không FK)
    detected_at      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    duration_seconds INT         NULL DEFAULT NULL,    -- NULL = không đo được thời gian dừng
    client_event_id  VARCHAR(36) NULL,                 -- UUID do app tạo, chống ghi trùng khi đồng bộ offline
    source           VARCHAR(20) NOT NULL DEFAULT 'MANUAL',   -- BEACON | MAP | MANUAL
    PRIMARY KEY (id),
    UNIQUE KEY uq_visits_user_event (user_id, client_event_id),
    KEY idx_visits_artifact (artifact_id),
    KEY idx_visits_user_detected (user_id, detected_at),
    CONSTRAINT chk_visits_duration CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Entity: Favorite (Phú). Mỗi người chỉ yêu thích 1 hiện vật 1 lần (khóa chính ghép).
CREATE TABLE IF NOT EXISTS likes (
    user_id     BIGINT   NOT NULL,
    artifact_id BIGINT   NOT NULL,
    saved_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, artifact_id),
    KEY idx_likes_artifact (artifact_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO visits (id, user_id, artifact_id, detected_at, duration_seconds, client_event_id, source) VALUES
    (1, 2, 1, '2026-10-05 09:10:00', 120, NULL, 'BEACON'),
    (2, 2, 2, '2026-10-05 09:20:00', 300, NULL, 'BEACON'),
    (3, 3, 1, '2026-10-06 14:05:00',  90, NULL, 'BEACON'),
    (4, 4, 3, '2026-10-07 10:30:00', 210, NULL, 'MANUAL');

INSERT INTO likes (user_id, artifact_id, saved_at) VALUES
    (2, 1, '2026-10-05 09:15:00'),
    (3, 1, '2026-10-06 14:10:00'),
    (4, 3, '2026-10-07 10:35:00');
