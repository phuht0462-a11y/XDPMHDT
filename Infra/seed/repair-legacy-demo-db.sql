-- Non-destructive migration for the three legacy demo artifacts from 03_content.sql.
-- Does not delete artifacts, translations, users, favorites, history or uploads.
-- Only the exact legacy example.com placeholder VIDEO row is removed.
-- ALWAYS run via repair-legacy-demo-db.ps1, which makes a database dump first.
USE content_db;
SET NAMES utf8mb4;
START TRANSACTION;

-- Replace only the three known placeholder thumbnails; preserve user-edited URLs.
UPDATE content_db.artifacts
SET thumbnail_url = CASE artifact_code
  WHEN 'KVC-01' THEN 'http://localhost:8080/api/media/files/d464fdca-51b3-4814-a223-734d2931f97e.jpg'
  WHEN 'BTS-01' THEN 'http://localhost:8080/api/media/files/7e657e40-50a1-4b32-b936-c8c14d47dc78.jpg'
  WHEN 'DM-01' THEN 'http://localhost:8080/api/media/files/1891c050-86f9-40e4-92b7-61137ea0bfc0.jpg'
  ELSE thumbnail_url
END, updated_at = NOW(6)
WHERE (artifact_code = 'KVC-01' AND thumbnail_url = 'https://example.com/media/kvc-thumb.jpg')
   OR (artifact_code = 'BTS-01' AND thumbnail_url = 'https://example.com/media/bts-thumb.jpg')
   OR (artifact_code = 'DM-01' AND thumbnail_url = 'https://example.com/media/dm-thumb.jpg');

-- Attach actual images to old VI/EN article rows that have none or demo URLs.
UPDATE content_db.artifact_contents c
JOIN content_db.artifacts a ON a.id = c.artifact_id
SET c.image_urls = CASE a.artifact_code
  WHEN 'KVC-01' THEN JSON_ARRAY('http://localhost:8080/api/media/files/64cb00c4-83c1-47d2-89d6-aa8e9f6bcdf6.jpg')
  WHEN 'BTS-01' THEN JSON_ARRAY('http://localhost:8080/api/media/files/2ca46f7f-9cf1-4d7f-8081-15f336b0edaa.jpg')
  WHEN 'DM-01' THEN JSON_ARRAY('http://localhost:8080/api/media/files/c7432a39-79c9-426e-99c2-e925b1bef6fc.jpg')
  ELSE c.image_urls
END, c.updated_at = NOW(6)
WHERE a.artifact_code IN ('KVC-01', 'BTS-01', 'DM-01')
  AND c.language_code IN ('vi', 'en')
  AND (c.image_urls IS NULL OR TRIM(c.image_urls) IN ('', '[]')
       OR c.image_urls LIKE '%example.com/%');

-- No Vietnamese narration was shipped. Remove only exact fake vi demo mp3 URLs;
-- keep any genuine user-uploaded Vietnamese voiceovers.
UPDATE content_db.artifact_contents c
JOIN content_db.artifacts a ON a.id = c.artifact_id
SET c.audio_url = NULL, c.updated_at = NOW(6)
WHERE c.language_code = 'vi'
  AND ((a.artifact_code = 'KVC-01' AND c.audio_url = 'https://example.com/audio/kvc-vi.mp3')
    OR (a.artifact_code = 'BTS-01' AND c.audio_url = 'https://example.com/audio/bts-vi.mp3')
    OR (a.artifact_code = 'DM-01' AND c.audio_url = 'https://example.com/audio/dm-vi.mp3'));

-- Replace only default English placeholder mp3 URLs, or absent demo audio.
UPDATE content_db.artifact_contents c
JOIN content_db.artifacts a ON a.id = c.artifact_id
SET c.audio_url = CASE a.artifact_code
  WHEN 'KVC-01' THEN 'http://localhost:8080/api/media/files/0dd6f7ac-f296-4176-b0a9-749787d863e3.wav'
  WHEN 'BTS-01' THEN 'http://localhost:8080/api/media/files/31938974-5e52-4b5c-b3dd-2043c3fa9c76.wav'
  WHEN 'DM-01' THEN 'http://localhost:8080/api/media/files/29cacba8-046d-4e1a-9355-9851766727f5.wav'
  ELSE c.audio_url
END, c.updated_at = NOW(6)
WHERE c.language_code = 'en'
  AND ((a.artifact_code = 'KVC-01' AND
         (c.audio_url IS NULL OR c.audio_url = 'https://example.com/audio/kvc-en.mp3'))
    OR (a.artifact_code = 'BTS-01' AND
         (c.audio_url IS NULL OR c.audio_url = 'https://example.com/audio/bts-en.mp3'))
    OR (a.artifact_code = 'DM-01' AND
         (c.audio_url IS NULL OR c.audio_url = 'https://example.com/audio/dm-en.mp3')));

-- The legacy seed lacks an EN description for Doan Mon. Insert ONLY if missing.
INSERT INTO content_db.artifact_contents
  (artifact_id, language_code, title, description, audio_url, video_url,
   image_urls, transcript, created_at, updated_at)
SELECT a.id, 'en', 'Doan Mon Gate',
       'Doan Mon is the southern gateway into the central area of the former imperial enclosure. Its relationship to the Kinh Thien Palace site helps visitors understand the arrangement of the historic royal complex.',
       'http://localhost:8080/api/media/files/29cacba8-046d-4e1a-9355-9851766727f5.wav',
       NULL, JSON_ARRAY('http://localhost:8080/api/media/files/c7432a39-79c9-426e-99c2-e925b1bef6fc.jpg'),
       NULL, NOW(6), NOW(6)
FROM content_db.artifacts a
WHERE a.artifact_code = 'DM-01'
  AND NOT EXISTS (SELECT 1 FROM content_db.artifact_contents c
                  WHERE c.artifact_id = a.id AND c.language_code = 'en');

-- Legacy image resource rows refer to exact known placeholders.
UPDATE content_db.media_resources m
JOIN content_db.artifacts a ON a.id = m.artifact_id
SET m.file_url = CASE a.artifact_code
    WHEN 'KVC-01' THEN 'http://localhost:8080/api/media/files/64cb00c4-83c1-47d2-89d6-aa8e9f6bcdf6.jpg'
    WHEN 'BTS-01' THEN 'http://localhost:8080/api/media/files/2ca46f7f-9cf1-4d7f-8081-15f336b0edaa.jpg'
    ELSE m.file_url END
WHERE m.media_type = 'IMAGE'
  AND ((a.artifact_code = 'KVC-01' AND m.file_url = 'https://example.com/media/kvc-1.jpg')
    OR (a.artifact_code = 'BTS-01' AND m.file_url = 'https://example.com/media/bts-1.jpg'));

-- No KVC video is part of the shipped seed. Remove ONLY this one fake video row.
DELETE m FROM content_db.media_resources m
JOIN content_db.artifacts a ON a.id = m.artifact_id
WHERE a.artifact_code = 'KVC-01' AND m.media_type = 'VIDEO'
  AND m.file_url = 'https://example.com/media/kvc.mp4';

-- If any legacy article has the matching fake video URL, clear that placeholder.
UPDATE content_db.artifact_contents c
JOIN content_db.artifacts a ON a.id = c.artifact_id
SET c.video_url = NULL, c.updated_at = NOW(6)
WHERE a.artifact_code = 'KVC-01'
  AND c.video_url = 'https://example.com/media/kvc.mp4';

COMMIT;

SELECT 'legacy_demo_artifacts' AS metric, COUNT(*) AS value
FROM content_db.artifacts
WHERE artifact_code IN ('KVC-01','BTS-01','DM-01');
SELECT 'remaining_example_com_urls' AS metric,
  (SELECT COUNT(*) FROM content_db.artifacts WHERE thumbnail_url LIKE '%example.com/%') +
  (SELECT COUNT(*) FROM content_db.artifact_contents
    WHERE audio_url LIKE '%example.com/%' OR video_url LIKE '%example.com/%' OR image_urls LIKE '%example.com/%') +
  (SELECT COUNT(*) FROM content_db.media_resources WHERE file_url LIKE '%example.com/%') AS value;
