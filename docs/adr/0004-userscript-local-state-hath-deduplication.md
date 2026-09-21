# ADR-0004: Userscript local-state H@H de-duplication

- Status: Accepted
- Date: 2026-09-17
- Related: [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md),
  [ADR-0005: Provider-authoritative uploader-revision chain projection](./0005-provider-authoritative-uploader-revision-chain-projection.md)

## Context

Yomiko exists partly to keep a local record of galleries already acquired or
requested through H@H and to expose that record while the user browses
ExHentai/E-Hentai. The product invariant is:

> **Use the userscript to reflect local DB state and help the user avoid duplicate H@H requests.**

This is a product requirement, not an implementation detail of the current
gallery-status query or CSS overlay. The userscript is the browsing-time view
of Yomiko's stable workflow state: it must say what happened to the exact GID,
whether another confirmed copy of the book is already archived, and what the
current rating/canonical role is. It must not turn a transient ordering between
identity, rating, and action workers into a user-facing product state.

The current model does not preserve that invariant across every known
same-book GID:

- fresh feedback creates or reactivates variant discovery only for ratings
  `8` through `11`, while migration 009 seeded historical ratings `1` through
  `11`;
- a low rating on a confirmed group sets `variant_groups.is_active=0`, and the
  class and userscript projections use active membership;
- an ungrouped low rating follows the legacy single-gallery path and does not
  establish an identity-tracking group;
- `gallery-status` reports acquisition history only for the requested GID and
  hides an H@H attempt when its timestamp is not newer than
  `rated_then_deleted_at`;
- the API does not return the gallery's local `self_rating`; and
- `web/yomiko.user.js` cannot show the score or carry a known same-book local
  state from one confirmed member to another.

Uploader revisions add a second boundary: a scoreable revision terminal can replace a
previous terminal before the new GID has a committed local archive. The
userscript must therefore resolve current identity through the shared terminal
projection while retaining exact-GID archive and H@H history; it must not copy
the predecessor's request watermark onto the replacement.

Consequently, rating and retention intent can erase the context needed to tell
the user that the exact GID was requested or that another confirmed GID is an
already downloaded copy of the book. The overloaded meaning of an **active**
group also makes later changes to schema, workers, retention, APIs, or the
userscript prone to specification drift.

## Decision

### The userscript is advisory and read-only

The durable local database is the authority for rating, acquisition, and
identity facts. The server derives a read-only projection and the userscript
displays it as information and a visual prompt. In this ADR, **avoid duplicate
requests** means helping the user make an informed choice; it does not mean
programmatically preventing a request.

The userscript and its read API must not:

- disable, intercept, reject, or turn an H@H request into a no-op;
- authorize a request or expose a `may_request` decision;
- change `yomiko hath`, `/api/hath_download.sh`, automatic worker behavior, or
  their locking/cooldown rules; or
- reconstruct local state from page ratings, DOM text, browser storage, or
  client-only history.

Direct CLI/API callers remain able to request H@H downloads. The read
projection is not a mutation preflight or authorization boundary.

### Project workflow meaning, not intermediate worker state

The projection must describe the converged meaning of the supported workflow,
even when identity discovery, rating synchronization, winner evaluation, and
action reconciliation are implemented as separate durable jobs. A state that
can exist only between those jobs is not automatically a valid userscript
presentation.

The supported workflow has these stable presentation outcomes:

| Workflow fact | Requested GID presentation | Required relation |
| --- | --- | --- |
| The user directly requests a GID through H@H | `hath_requested` ("requested") on that GID | `exact` |
| Ratings `1` through `10` have been projected to a confirmed class | The exact numeric rating on every confirmed member | No related request presentation |
| Rating `11` selects and requests a new canonical winner | `hath_requested` on the winner being requested | `exact` |
| Rating `11` leaves a lower-scoring confirmed member behind | `rated_11_alternate` on that member | No related request presentation |
| The canonical archive has been committed | `rated_11_canonical` ("archived") on the canonical GID | `exact` |
| Only another confirmed member has a committed archive | `downloaded_unrated` ("same book downloaded") | `same_book` |

There is deliberately no stable **same-book requested** presentation. A manual
request is exact to the GID the user chose. An automatic rating-11 replacement
request is exact to the selected winner, while the displaced member is an
alternate. Before or after those facts converge, another member's attempt or
accepted-request watermark must not be lifted into `hath_requested` for the
requested GID.

Accordingly, Yomiko's authoritative projection must satisfy all of these
requirements:

- `hath_requested` is derived only from the requested GID's own current H@H
  watermark;
- every `hath_requested` result has `local_state_relation='exact'` and
  `local_state_gid` equal to the requested GID;
- `authorized_attempt` and `accepted_request` remain durable exact-GID history
  but never propagate across a confirmed identity class for userscript
  presentation;
- `same_book` acquisition presentation is reserved for a committed archive
  owned by another confirmed member;
- `local_state_relation` is `NULL` when no exact request/archive or related
  committed archive supplies the presented acquisition state; and
- the userscript must not contain or synthesize a "same book requested" label.

### Start identity discovery after feedback for every rating

Do not start variant discovery merely because a gallery was scanned or
downloaded. Preserve the current workflow trigger: discovery begins after the
user submits feedback.

Once feedback supplies a rating, every rating `1` through `11` must establish
or retain identity tracking and queue discovery under the existing scoreable
revision-terminal variant scope (`Manga` + `language:chinese` +
`other:tankoubon`). Identity
discovery is required alongside remote rating synchronization regardless of
the score. Historical backfill and new feedback must express the same rule.

The rating continues to control remote rating value, favorite routing, archive
retention, and automatic H@H replacement. It must not decide whether same-book
identity is tracked.

Feedback establishes the rating before discovery can confirm another member.
When a candidate becomes a current confirmed member, the local database
transition or the authoritative read projection must make that class's current
rating and rating-11 role visible at the same read boundary. The userscript
must not observe a confirmed member as unrated merely because a later action
worker has not yet copied the rating into that gallery row. In particular,
such a synchronization gap must never expose a related request as the member's
primary state.

### Keep three concerns independent

The product model must not use one flag or timestamp to stand for all of these
concerns:

1. **Same-book identity:** which GIDs are durably confirmed to represent the
   same logical book, plus which candidate relationships remain unresolved.
2. **Local acquisition history:** exact-GID facts durably recorded in the
   database, such as a committed archive, an authorized H@H attempt, and an
   accepted H@H request. Confirmed identity permits committed archives, but
   not request watermarks, to become logical-book presentation evidence.
3. **Desired operations:** the current rating, favorite routing, local-file
   retention, automatic replacement, and cleanup policy.

A low desired rating may suppress file retention and replacement actions. It
must not discard confirmed same-book identity or delete durable acquisition
history. The userscript may nevertheless present a newer deletion/rating state
instead of an older request state under the lifecycle precedence below.

### Require identity review for every rating, canonical selection only for 11

An uncertain same-book candidate requires the same user review for ratings
`1` through `11`. Pending candidate evidence is not identity and must not
inherit another gallery's local state before the user or authoritative chain
evidence confirms it.

Canonical winner selection exists to ensure that only one local file is kept
for a confirmed same-book class. It therefore applies only when the desired
rating is `11`:

- ratings `1` through `10` perform discovery and any necessary same-book
  reviews, but do not create a canonical winner review or require a canonical
  winner to finish the identity workflow; and
- rating `11` retains the current canonical selection and automatic H@H
  replacement workflow. Requesting the selected canonical GID remains an
  intentional exception even when another confirmed same-book member has
  local acquisition history.

Below `11`, identity reconciliation completes after the necessary same-book
decisions and does not require canonical scoring or evaluation. Scoring a
winner without a one-file retention requirement would create a canonical
concept with no product purpose.

Canonical state from an earlier rating `11` may remain audit history after a
downgrade, but it must not be presented as a current winner requirement for a
rating `1` through `10` class.

### Project confirmed-class state and the exact local score

Only committed-archive acquisition state may propagate across the current
confirmed same-book identity class. Request attempts and accepted requests are
exact-GID facts for presentation. No acquisition state may propagate across an
unresolved candidate or a known `different_book` relationship.

For each requested GID, the read contract must return its exact gallery-row
`self_rating` as an integer using the existing `0` (unrated) and `1` through
`11` meanings. When rating is the current presentation state, the userscript
shows the actual score rather than the generic `rated_non_11` label. It
continues to present a gallery with `self_rating=0` as unrated.

The projection must distinguish enough server-owned facts to show whether a
committed archive belongs to the exact GID or another confirmed same-book
member. Request information is reported only for the exact GID. The API
retains the score even when a newer exact request or an alternate state wins
the primary userscript presentation. No returned field grants or denies
permission to request.

When a class is merged, split, or reactivated, discovery, review, the read API,
and the userscript must use the same current identity authority. Historical
rows that no longer define the current class may remain audit evidence but
must not create a false current relationship.

### Use lifecycle watermarks, not permanent attempt display

For each gallery row, define:

```text
latest_hath_at = max(hath_last_attempted_at, hath_requested_at)
```

The userscript presents `hath_requested` only when that watermark is strictly
newer than `rated_then_deleted_at` and no completed local-file state supersedes
the pending-download presentation. Equality does not count as a newer request.
The timestamps remain durable history, but an old attempt is not displayed
forever as the gallery's current state.

When `rated_then_deleted_at` is newer than or equal to the H@H watermark:

- a confirmed non-canonical member of a current rating-11 class is displayed
  as the alternate; and
- a gallery whose current `self_rating` is `1` through `10` is displayed with
  that numeric rating.

Derive this exact-member lifecycle state before considering a confirmed
same-book class. A related member contributes only a current committed archive;
its authorized-attempt and accepted-request watermarks never contribute to the
requested member's presentation. The class projection identifies exact versus
related archive evidence, while every presented request remains exact.

### Keep the contract change-controlled

Schema, migration, feedback, discovery, review, evaluation, retention, read
API, and userscript changes must preserve this decision. Any change to the
feedback trigger, rating scope, confirmed-class boundary, rating-11-only
canonical rule, `self_rating` meaning, or read-only presentation boundary must
update this ADR, feature documentation, and acceptance tests before the
implementation changes.

## Consequences

Positive consequences:

- Every rated scoreable revision terminal receives the same identity-discovery behavior,
  while unrated downloads do not start work early.
- A rating or retention transition cannot silently erase the same-book context
  presented by the userscript.
- Low-rated classes still obtain necessary identity decisions without creating
  meaningless canonical winner work.
- The userscript shows the exact local score and remains a small presentation
  client of one testable server projection.
- Users never see a "same book requested" label that can only be produced by
  an intermediate or inconsistent projection.
- Existing manual and automatic H@H mutation behavior remains outside this
  read-only feature.

Costs and constraints:

- The current use of `variant_groups.is_active` for identity, scheduling, and
  desired operations must be separated or replaced by an equally explicit
  authority.
- Historical data needs a deterministic backfill; migration 009's broad seed
  and the narrower current feedback path cannot remain semantically different.
- The gallery-status contract requires a coordinated API/userscript change to
  include `self_rating` and related-member provenance.
- Unknown candidates cannot be used for presentation de-duplication, so human
  review remains necessary before cross-GID state can be asserted.

## Rejected alternatives

- **Discover on scan before feedback:** starts network and review work earlier
  than the selected workflow and does not have a user rating intent.
- **Treat low rating as loss of identity:** couples user preference to a fact
  about whether two GIDs are the same book and recreates the motivating bug.
- **Create winner reviews below 11:** canonical winner exists for one-file local
  retention, which ratings `1` through `10` do not request.
- **Check only the requested GID:** cannot present the cross-GID part of the
  user story once same-book identity is confirmed.
- **Let the userscript infer identity:** duplicates matching policy in an
  untrusted, DOM-dependent client and cannot see durable server history.
- **Propagate across pending candidates:** turns uncertain evidence into a
  false de-duplication statement.
- **Propagate a related member's H@H request:** creates a presentation that is
  absent from the converged workflow. Manual requests belong to their exact
  GID; automatic replacement requests belong to the exact rating-11 winner.
- **Add a userscript/API/CLI request guard:** contradicts the selected advisory
  contract; presentation must not become authorization or enforcement.

## Verification contract

Acceptance coverage must demonstrate at least these scenarios:

- a scoreable downloaded gallery does not enter identity discovery before
  feedback;
- fresh feedback ratings `1`, `7`, `8`, `10`, and `11` all seed or retain
  identity discovery and remote rating synchronization;
- ratings `1` through `10` can require candidate same-book review but never
  create a canonical winner review or automatic replacement H@H action;
- rating `11` retains canonical selection and may intentionally request its
  selected canonical replacement;
- lowering and reactivating a confirmed class preserves its authoritative
  membership and identity-review evidence;
- committed archives are reflected across confirmed same-book members with an
  exact-versus-same-book local-state relation, but request attempts are not,
  and neither kind crosses an unresolved candidate or known `different_book`
  edge;
- the API returns exact `self_rating`; when rating is the current state, the
  userscript presents scores `1` through `10` without mistaking `0` for a
  score;
- a strictly newer exact-GID H@H watermark displays `hath_requested` with
  exact provenance, while a newer or equal deletion watermark displays the
  numeric `1` through `10` rating or the rating-11 alternate state according
  to the deletion cause;
- neither a current nor stale related-member request propagates, while a
  current committed archive does propagate from a confirmed same-book member;
- rating-11 winner replacement displays an exact request on the selected
  winner and the alternate state on the displaced member, never a same-book
  request on either member;
- the CLI/API/userscript projection agrees for the same fixture; and
- neither the userscript nor its read API alters H@H request behavior.
