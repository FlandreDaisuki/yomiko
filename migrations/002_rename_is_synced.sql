-- SQLite does not support ALTER TABLE ALTER COLUMN or DROP COLUMN across all versions simply.
-- The most robust way to change a column type and default in SQLite is to recreate the table.
-- However, SQLite 3.25.0+ supports RENAME COLUMN, but changing the type/default still requires table recreation or just adding a new column and dropping the old one (SQLite 3.35.0+ supports DROP COLUMN).

-- Since we want to change the type, semantics, and rename it, adding a new column, updating the data, and dropping the old one is the cleanest approach if SQLite >= 3.35.0.

ALTER TABLE galleries ADD COLUMN feedbacked_at TEXT;

UPDATE galleries
SET feedbacked_at = CASE
    WHEN is_synced = 0 THEN NULL
    ELSE (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
END;

ALTER TABLE galleries DROP COLUMN is_synced;
