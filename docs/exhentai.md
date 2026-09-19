# ExHentai provider behavior

- Status: Living external-behavior record
- Last updated: 2026-09-19
- Scope: ExHentai/E-Hentai Web, API, and H@H behavior that Yomiko relies on

This document records externally owned behavior. It does not define Yomiko's
domain vocabulary, architecture, or policy decisions:

- [Domain language](./domain-language.md) defines what Yomiko terms mean.
- [Architecture](./architecture.md) describes how Yomiko integrates with the
  provider.
- ADRs record the decisions Yomiko makes because of provider behavior.
- Plans and research records preserve implementation analysis and one-time data
  observations.

## Evidence labels

Each fact should identify its evidence strength:

- **Documented:** stated by an official provider document.
- **Confirmed observation:** repeatedly observed or explicitly confirmed as an
  operating fact, but not necessarily promised by provider documentation.
- **Working assumption:** required by the current design but not yet confirmed.
  Code must fail safely if it is false.

Record the last confirmation date and the affected Yomiko boundary. Do not turn
a production-snapshot pattern into a provider guarantee without independent
evidence.

## Web behavior

### Userscript-visible galleries are current uploader revisions

- Evidence: **Confirmed observation**
- Last confirmed: 2026-09-19
- Boundary: `web/yomiko.user.js` and gallery-status presentation

On the ExHentai/E-Hentai Web surfaces where Yomiko's userscript operates, an
uploader revision chain is presented through its current gallery revision. The
userscript therefore normally queries and displays state for the current GID;
it does not need a separate `uploader_revision` provenance value.

This Web visibility fact does not imply that:

- older revisions can be discarded from `galleries` or audit history;
- API/discovery inputs contain only current revisions;
- a current page is enough to reconstruct or validate the uploader revision
  chain; or
- equal `uploader` metadata establishes chain membership.

ADR-0004's existing userscript `local_state_relation` projection remains
unchanged. Uploader-revision validation and terminal-only current group
projection are separate server-side concerns governed by
[ADR-0005](./adr/0005-provider-authoritative-uploader-revision-chain-projection.md).

## API behavior

### Gallery metadata can expose uploader-revision references

- Evidence: **Documented example plus confirmed observations**
- Last confirmed: 2026-09-19
- Boundary: gdata normalization and variant discovery

The API can return `first`, `parent`, and `current` gallery identity references
as a GID plus gallery token/key. The official
[EHWiki API page](https://ehwiki.org/wiki/API) includes these fields in its
gdata example, but does not define a stable chain identifier or guarantee the
presence semantics needed to use `first` as one.

Yomiko therefore:

- preserves and token-validates all three relation pairs;
- uses validated `parent`/`current` paths for uploader-revision projection;
- uses `first` for traversal and consistency evidence, not as a chain ID; and
- treats missing, incomplete, or malformed relation closure as retryable
  ingestion state rather than a same-book review question.

Detailed repository and production-snapshot observations remain in the
[research ledger](./plans/2026-09-19-uploader-revision-chains-research.md). They
are evidence for tests and migration design, not additional provider promises.

### Uploader metadata does not identify a revision chain

- Evidence: **Confirmed observation**
- Last confirmed: 2026-09-19
- Boundary: uploader-revision validation and same-book matching

One uploader can create multiple galleries without connecting them through the
provider's revision mechanism. Equal `uploader` values therefore do not prove
that two galleries belong to one uploader revision chain. Distinct chains owned
by the same uploader may still contain the same book and can enter normal
cross-chain `same_book`/`different_book` matching, decision, and review.

## Adding a provider fact

For each new fact, record:

1. the narrow external behavior;
2. its evidence label and last confirmation date;
3. the Web/API/H@H boundary where it applies;
4. what the fact explicitly does not prove; and
5. the ADR, architecture section, or test that consumes it.

If the document grows into several independently maintained contracts, move it
to `docs/providers/exhentai/` and split it by Web, API, and H@H boundary. Do not
create that hierarchy before it reduces real navigation or ownership cost.
