-- Publish the shared public lifecycle projection for review presentation and
-- retained outcome metrics.  This view is deliberately read-only and has one
-- row per durable review; it does not apply visibility or actionability rules.
CREATE VIEW variant_review_product_lifecycle AS
SELECT review.id AS review_id,
       CASE WHEN review.superseded_at IS NOT NULL
            THEN 'resolved' ELSE review.status END AS projected_status,
       CASE WHEN review.superseded_at IS NOT NULL
            THEN 'superseded' ELSE review.decision END AS resolution
  FROM variant_reviews AS review;
