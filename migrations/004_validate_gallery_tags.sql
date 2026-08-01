CREATE TRIGGER IF NOT EXISTS validate_gallery_tags_on_insert
BEFORE INSERT ON galleries
WHEN CASE
    WHEN NEW.tags IS NULL THEN 1
    WHEN json_valid(NEW.tags) = 0 THEN 1
    ELSE json_type(NEW.tags) <> 'array'
END
BEGIN
    SELECT RAISE(ABORT, 'galleries.tags must be a JSON array');
END;

CREATE TRIGGER IF NOT EXISTS validate_gallery_tags_on_update
BEFORE UPDATE OF tags ON galleries
WHEN CASE
    WHEN NEW.tags IS NULL THEN 1
    WHEN json_valid(NEW.tags) = 0 THEN 1
    ELSE json_type(NEW.tags) <> 'array'
END
BEGIN
    SELECT RAISE(ABORT, 'galleries.tags must be a JSON array');
END;
