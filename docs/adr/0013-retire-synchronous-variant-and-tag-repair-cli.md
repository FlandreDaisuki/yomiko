# ADR-0013: Retire synchronous variant evaluation and legacy tag repair CLI

- Status: Accepted
- Date: 2026-10-01
- Related:
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md),
  [Architecture](../architecture.md),
  [Migration 004](../../migrations/004_validate_gallery_tags.sql)

## Context

The CLI exposed `yomiko variants evaluate <gid>` as a synchronous way to start
scoring, alongside the durable `evaluate` job handled by `yomiko variants
work`. The public GID wrapper was only used by that command. The worker already
calls `variants_evaluate_group` directly and guards the result with the job's
expected evaluation ID.

The CLI also exposed `yomiko repair-tags` to fetch metadata and fill legacy
`galleries.tags IS NULL` values. Migration 004 installs `BEFORE INSERT` and
`BEFORE UPDATE OF tags` triggers that reject null or non-array tags. The
provider boundary `exh_normalize_gallery_metadata` validates tags as an array
of strings. `gallery_upsert_metadata` requires the array shape for already-
normalized metadata and otherwise uses that provider normalizer; variant
discovery publishes metadata validated at the same provider boundary through
the database triggers. There is no current application write path that creates
a new gallery with null tags while migration 004's triggers are installed.

The triggers do not backfill rows that were already null. The migration test
inserts a null-tag row before applying migration 004, confirms it remains null,
and confirms that new null inserts and tag updates to null are rejected. Other
column updates do not target `tags` and can leave such legacy values in place.
Migration 027 can fill missing tags from an available variant metadata
snapshot for affected members, but this is not a general repair for every
pre-existing null row.

## Decision

Remove `yomiko variants evaluate <gid>` and its GID-to-group wrapper. Do not
add an alias. Scoring remains available through durable `evaluate` jobs and
`yomiko variants work`; retain `variants_evaluate_group`, worker dispatch, and
their scoring and persistence tests.

Remove `yomiko repair-tags` from the public CLI, database component registry,
README, architecture command reference, and CLI behavior tests. Do not add a
replacement command, script, or alias. Keep migration 004 unchanged. This
release removes the command without providing a replacement repair path.

## Consequences

Invocations of both retired command forms fail with a nonzero usage error, and
neither appears in CLI help. Automated variant evaluation continues through
the existing durable worker path.

Installations may retain legacy gallery rows with `tags IS NULL`; there is no
supported repair path for those rows in this release. Migration 004 continues
to prevent current application ingestion from creating new null-tag rows, and
the architecture reference records the legacy-data limitation.

## Verification

Focused playground regressions passed for retired-command rejection, legacy
null-tag migration behavior, variant scoring and persistence, durable worker
dispatch, revision-chain consumers, and request-bounded list projection. The
full playground suite passed: 194 tests, 0 failures. `bash -n` and
`git diff --check` passed. ShellCheck ran but reported existing warnings in
unchanged CLI, helper, test-stub, and fixture lines.
