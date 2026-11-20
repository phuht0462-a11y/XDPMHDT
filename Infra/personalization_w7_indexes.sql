-- W7 / Phu. Run on the existing MySQL volume. Do not reset or reseed the database.
-- Requires personalization_db.visits to exist; rerunning is safe.
SET @index_exists = (
    SELECT COUNT(*) FROM information_schema.statistics
    WHERE table_schema = 'personalization_db' AND table_name = 'visits'
      AND index_name = 'idx_visits_user_detected'
);
SET @index_sql = IF(@index_exists = 0,
    'ALTER TABLE personalization_db.visits ADD INDEX idx_visits_user_detected (user_id, detected_at)',
    'SELECT ''idx_visits_user_detected already exists'' AS result');
PREPARE personalization_index_stmt FROM @index_sql;
EXECUTE personalization_index_stmt;
DEALLOCATE PREPARE personalization_index_stmt;
SHOW INDEX FROM personalization_db.visits WHERE Key_name = 'idx_visits_user_detected';
