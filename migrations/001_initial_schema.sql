CREATE TABLE IF NOT EXISTS galleries (
    -- Primary Keys and Metadata from ExHentai
    gid            INTEGER PRIMARY KEY,
    token          TEXT,
    title          TEXT NOT NULL,
    title_jpn      TEXT,
    file_count     INTEGER,
    expunged       BOOLEAN DEFAULT 0,
    tags           TEXT,                    -- Stored as JSON array: ["tag1", "tag2"]
    rating         REAL DEFAULT 0.0,        -- Average rating from ExHentai

    -- Local File State (Handled by archive-gallery)
    file_path      TEXT,                    -- Points to the .7z archive

    -- Ratings & Sync Logic
    self_rating    INTEGER DEFAULT 0,       -- 0: unrated, 1 - 11: user rated
    is_synced      INTEGER DEFAULT 0,       -- 0: local only, 1: synced back to ExHentai

    -- Lifecycle Timestamps (Stored as ISO 8601 TEXT)
    created_at            TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at            TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    rated_then_deleted_at TEXT              -- Track when disk was cleaned
);

-- Version tracking for migrations
CREATE TABLE IF NOT EXISTS _schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at DATETIME DEFAULT current_timestamp
);

INSERT OR IGNORE INTO _schema_version (version) VALUES (1);

-- Indices for performance
CREATE INDEX IF NOT EXISTS idx_gid_token ON galleries(gid, token);
CREATE INDEX IF NOT EXISTS idx_unrated ON galleries(rating) WHERE rating = 0;
