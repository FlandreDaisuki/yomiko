# ADR-0006: Discovery, revision, and archive vocabulary

- Status: Accepted
- Date: 2026-09-21
- Related: [Domain language](../domain-language.md),
  [ADR-0005: Provider-authoritative uploader-revision-chain projection](./0005-provider-authoritative-uploader-revision-chain-projection.md)

## Context

The implementation had several names for the same provider-revision and local
archive roles. `eligible_galleries` described a scoreable revision terminal,
`available_galleries` described the exact local archive source, and
`uploader_revision_representatives` mixed the current provider projection with
same-book and canonical terminology. That ambiguity made it easy for a query
to confuse a canonical gallery, a replaced revision, and an archive fallback.

Discovery also has two separate boundaries: candidates are staged while a run
collects provider facts, and publication atomically applies a complete run
snapshot. A fetched gallery is not a current member until that publication
succeeds.

## Decision

The following names are normative for new implementation and documentation:

| Old name | Canonical name | Meaning |
| --- | --- | --- |
| `uploader_revision_members` | `revision_members` | Every fetched revision in a provider component, including replaced revisions. |
| `uploader_revision_representatives` | `current_revision_projection` | Current authoritative provider-revision result, including readiness and bounded blocking reason. |
| `eligible_galleries` | `scoreable_revision_terminals` | Unique complete terminal with required scope and scoring inputs. |
| `available_galleries` | `archive_source_galleries` | Nullable mapping from a scoreable terminal to the exact GID owning the safe committed archive. |
| candidate gallery | identity candidate | A scoreable terminal awaiting a same-book identity decision. |
| alternate gallery | non-canonical member | A confirmed member that is not the canonical gallery. |
| publish result | publication | The atomic run-level operation applying a complete discovery snapshot. |

The archive-source row is intentionally nullable. `archive_gid IS NULL`
means that no committed local archive is currently safe for the target; it does
not mean that the target is missing, stale, or non-canonical. A non-null source
GID may be a replaced revision while its successor is being acquired. Thus a
scoreable revision terminal, canonical gallery, and archive source may be
different GIDs. For example, after `102 -> 103` is published, `103` is the
scoreable terminal and `archive_source_galleries` may map it to `102` while
`201` remains the canonical gallery selected for the surrounding same-book
group. In another group, `103` may itself be canonical; canonical selection
and provider-revision projection are separate decisions. The predecessor
`102` remains the archive source until `103` is committed locally.

If the fetched replacement is blocked, for example because confirmed target
`103` has `ready = 0`, publication does not replace the last committed current
projection. The confirmed member and archive source therefore remain `102`
until a complete publication succeeds; `103` remains blocked provider evidence,
not a scoreable terminal or a reason to clear the fallback.

The actual discovery phases remain the code-owned sequence:
`seed_refresh`, `chain_walk`, `search`, `gdata`, `popularity`, and `publish`.
The last phase is a publication transaction, not a state assigned to a gallery.
Candidate states distinguish staged work from a complete publication input;
`state = 'complete'` means that the candidate passed collection, not that it
is itself a scoreable revision terminal.

Migration 028 adds the canonical read-only views and removes the old view
objects. Historical migrations and immutable JSON evidence are not edited.
The current runtime producer and CLI/API boundary emit the canonical evidence
keys; historical rows are normalized when serialized.

The persisted-evidence backfill removes historical `eligible` and
`uploader_revision.candidate_eligible`; current producers and
CLI/API serializers emit only `is_revision_terminal` and
`uploader_revision.candidate_is_revision_terminal`.
`official_chain_visibility.eligible` is
historical policy data removed from the active policy during migration
finalization, not an active serialized field. None of these historical
spellings authorizes current identity, scoring, or archive decisions; current
implementation uses the canonical views and terms recorded in the
domain-language migration register.

## Naming gate

Before adding a domain term or verb, verify that users can explain its meaning
and that it is not ambiguous with an existing role, state, or operation. New
code must not introduce `live graph`, `published gallery`, `accepted discovery
member`, `discovery done gallery`, or `revision last`. `reviewable` remains a
review property, `confirmed member` remains same-book identity state, and
`canonical gallery` remains distinct from `archive source gallery`.

## Consequences

Consumers can read the role directly from the identifier, and nullable archive
handoff semantics are explicit. The old view names remain only in historical
migrations and the migration register; they are not runtime compatibility
aliases.
