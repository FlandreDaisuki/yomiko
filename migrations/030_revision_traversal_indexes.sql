-- Target-seeded uploader-revision walks seek incoming parent/current edges
-- instead of scanning every gallery row at each recursive step.  Keep
-- incomplete relation pairs indexed so validation and relation guards still
-- see malformed staging facts; the projection checks the token pair before
-- accepting an edge.
CREATE INDEX idx_galleries_parent_gid
ON galleries(parent_gid)
WHERE parent_gid IS NOT NULL;

CREATE INDEX idx_galleries_current_gid
ON galleries(current_gid)
WHERE current_gid IS NOT NULL;
