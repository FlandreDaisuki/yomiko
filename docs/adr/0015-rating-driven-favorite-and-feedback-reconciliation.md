# ADR-0015: Rating-driven favorites and durable feedback reconciliation

- Status: Accepted
- Date: 2026-10-02
- Related:
  [Architecture](../architecture.md),
  [Gallery variants](../gallery-variants.md),
  [ADR-0004: Userscript local-state H@H de-duplication](./0004-userscript-local-state-hath-deduplication.md),
  [ADR-0009: External interface latency budgets](./0009-external-interface-latency-budgets.md)

## Context

Feedback accepted a favorite category even though durable variant reconciliation
already owned favorite changes for grouped galleries. The web page also always
sent category `5`. This made the option appear configurable while the worker
projected its own canonical/alternate policy, and a new ungrouped rating from
`1` through `7` bypassed the worker entirely. That fallback synchronously sent
the remote rating and did not create the identity/discovery work required by
ADR-0004.

ADR-0009 previously exempted ungrouped low feedback from its sub-second API
budget because it waited for ExHentai. The feedback API already used durable
reconciliation for grouped low ratings and high ratings, so the existing
worker can own the formerly ungrouped low path as well.

## Decision

Remove `--favorite` from `yomiko feedback` and reject the `favorite` API query
parameter with `400 Bad Request`. The feedback page sends only GID and rating.
Remote rating and favorite operations are worker-owned for every rated
feedback path. Their behavior and local archive handling are:

| Rating | Remote rating | Remote favorite | H@H / archive |
| --- | --- | --- | --- |
| `1`–`7` | Worker sends the exact rating. | Worker removes favorites from every confirmed member. | No H@H request; worker cleans confirmed-member archives. |
| `8`–`10` | Worker sends the exact rating. | Worker moves every confirmed member to the configured alternate category. | No H@H request; the submitted source archive is deleted on the request path, and other confirmed-member archives are cleaned by the worker. |
| `11` | Worker sends remote rating `10`. | After the canonical winner is resolved, the worker moves it to the configured canonical category and other confirmed members to the alternate category. | Worker requests the canonical through H@H when needed and retains one safe archive. |

Every feedback request with a rating from `1` through `11` creates or reuses
the current identity group through `variants_enqueue_feedback` and queues
discovery and durable reconciliation. The worker applies remote ratings and
favorite actions. For low ratings it also deletes confirmed-member archives;
`rated_then_deleted_at` is set only after the worker confirms an actual
deletion. Ratingless CLI feedback records only `feedbacked_at` and queues no
favorite or rating operation.

Ratings `8` through `10` retain the existing request-path deletion of the
submitted source archive after durable intent is enqueued. Other confirmed
member archive cleanup remains worker-owned. Rating `11` retains the source
archive until canonical retention is reconciled. Every rated API response has
`variant_queued: true`.

Favorite category configuration remains in
`YOMIKO_CANONICAL_FAVORITE_CATEGORY` and
`YOMIKO_ALTERNATE_FAVORITE_CATEGORY`. Values must be distinct integers from
`0` through `9`. Missing or invalid configuration puts only favorite actions
into configuration error; rating and archive actions continue independently.
Configuration recovery reprojects the current desired favorite state.

## Rationale and consequences

Reusing the existing group action queue avoids a synchronous ExHentai favorite
request on the feedback response path and closes ADR-0004's fresh low-rating
identity gap. The API returns after local persistence/enqueue, under the
current strict budget in ADR-0009. Failed or unavailable remote operations
remain visible as durable worker action state and retry according to policy.
Remote rating/favorite state and low-rated archive cleanup can therefore lag
the feedback response.

Fresh ungrouped low ratings now create an identity group, discover candidates,
and may create same-book review work. This is the intended all-ratings identity
contract from ADR-0004. It replaces the historical synchronous rating and
immediate archive deletion behavior with queued worker actions. Ratings `8`
through `10` keep their existing synchronous source-archive deletion; that
request-path filesystem operation remains separately covered by the interface
contract.

There is no schema migration. Existing remote state is reconciled from the
current rating projection. Older clients that submit `--favorite` or the API
`favorite` parameter receive an explicit error and must omit it. The API's
`variant_queued` value changes from `false` to `true` for formerly ungrouped
low ratings. The standalone `yomiko favorite <gid> <0~9>` command remains
available for an explicit manual category change; only the feedback override
has been removed.

## Alternatives considered

- Keep a direct synchronous `favdel` call for ungrouped low ratings. This adds
  a credential lookup and remote action request to the feedback response and
  retains the old exception to the sub-second budget.
- Remove favorites only for galleries that already have a group. This breaks
  the rating policy for fresh ungrouped galleries.
- Add a separate single-gallery background queue. The existing durable group
  action model already handles rating, favorite removal, retries, archive
  cleanup, and later confirmed members, so a second queue would duplicate it.
- Keep accepting a caller-selected category. It conflicts with the fixed
  canonical/alternate rating policy and can be undone by policy projection.

## Verification

On the recreated current-worktree playground, focused regressions passed:
fresh ungrouped low-rating reconciliation (1), feedback API (3), 8–10 alternate
category projection and recovery (1), rating transition convergence (1), and
the per-pass remote action budget (1): 7 passed, 0 failed. The fresh low test
verified identity-group creation, confirmed source membership, queued
discovery/reconcile work, durable rating/favorite-removal/archive-cleanup
actions, no synchronous ExH request, and deletion timestamp semantics. It also
verified API `variant_queued: true`, ratingless timestamp-only behavior, and
that `--favorite` is rejected before mutation. The budget test verified passes
of 25, 25, and 2 actions followed by completion.

The complete suite passed 205 tests with 0 failures. The isolated API latency
benchmark measured 20 warm requests per route: fresh ungrouped rating `3` had
p95 `187ms`, compared with grouped rating `3` at `207ms`; ratings `8`, `9`,
`10`, and `11` measured `244ms`, `267ms`, `233ms`, and `267ms`. All measured
local and feedback routes remained below the strict one-second budget. The
benchmark could not reach its decision-resolution samples because the copied
snapshot lacked 21 authenticated pending candidate reviews; that fixture-gated
route has no post-change measurement here.

ShellCheck, Bash syntax validation, and `git diff --check` passed. The full
suite included the SQLite writer-gate regressions; no production remote writes
were enabled.
