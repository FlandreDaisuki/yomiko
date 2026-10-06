-- Candidate review closure looks up pending reviews from a candidate GID.
CREATE INDEX idx_variant_reviews_pending_candidate_endpoint
ON variant_reviews(candidate_gid, group_id, id)
WHERE review_type='candidate_identity' AND status='pending';
