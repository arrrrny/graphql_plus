# Implementation Plan: Harden the 5.x line and audit it for the 6.x rewrite

**Branch**: `001-5x-hardening` | **Spec**: [spec.md](./spec.md) | **Created**: 2026-11-12

## Summary

Make `graphql_plus` / `graphql_flutter_plus` presentable and verifiable, then record what the
5.x architecture got wrong so the 6.x rewrite has a target. Three workstreams: (1) documentation
and metadata cleanup, (2) a green analyze/test baseline on a clean checkout, (3) the
design-failure audit and the release-line triage of the transferred upstream backlog.

This plan covers the *completed* work in commit `4eee571` and the verification that proves it;
the four `5.x`-labelled issue fixes are separate specs.

## Technical Context

**Language**: Dart 3 (pure Dart client) / Flutter (widgets package)
**Monorepo**: Melos, `packages/**`, `usePubspecOverrides: true`
**Primary commands**: `dart analyze --fatal-infos` + `dart test`;
`flutter analyze --fatal-infos` + `flutter test`; `make check` for both
**Testing**: `package:test` (client), `flutter_test` (widgets)
**Dependencies relevant here**: `gql_*`, `normalize`, `hive_ce`, `http`, `flutter_hooks`
**Source roots**: `packages/graphql_plus/lib/src`, `packages/graphql_flutter_plus/lib/src`

## Constitution Check

| Principle | Status |
| --- | --- |
| I. Test-first | N/A for docs/metadata; the deprecated-import fix is verified by the analyzer gate |
| II. Clean architecture | Not applicable to 5.x; audited in `DESIGN_FAILURES.md` instead |
| III. Public API compatibility | Respected — no signature changes; 5.2.6 adds only a callback |
| IV. Fail loud | Respected — no error handling changed |
| V. Simplicity / YAGNI | Respected — no dependency added or upgraded |

## Workstreams

### A. Documentation and metadata (done)

Remove another project's community furniture from files this fork publishes:

- root `README.md`: hiring banner, Discord badge and `[discord-*]` definitions, the
  `laanwj/rust-clightning-rpc` CI badge, upstream-only pub/coverage/license/version badges,
  GitHub watchers/stars badge definitions, the OpenCollective image gallery.
- `packages/*/README.md`: same badge set; header blocks rewritten for the fork.
- `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/bug_report.md`: Discord contact lines replaced with
  "open an issue".
- `.github/FUNDING.yml`: `open_collective: graphql-flutter` removed (it funded the upstream).
- Relative link sweep: 7 occurrences in the root README and 11 in the widgets README pointed at
  the pre-rename `packages/graphql/` path.

Kept deliberately: the Zuraffa launch block at the top of the root README, the upstream fork
note at the bottom, and all historical `CHANGELOG.md` content.

### B. Green baseline (done)

`packages/graphql_flutter_plus/lib/src/widgets/cache_provider.dart` and
`lib/src/hive_init.dart` imported `package:flutter/material.dart` while using only
`WidgetsFlutterBinding`. On Flutter 3.47.0+ that import is an `info`-level
`deprecated_member_use`; `--fatal-infos` promotes it to an error, so `flutter analyze` failed on
a clean checkout. Both now import `package:flutter/widgets.dart`.

Remaining, deliberately unfixed: 9 `deprecated_member_use` infos in `example/` and `test/` —
a Material migration, not a 5.x fix.

### C. Triage and audit (done)

- `UPSTREAM_ISSUES_TRIAGE.md`: added a "Triage decisions — 5.x vs 6.x" section stating the rule
  (5.x = no breaking change; 6.x = breaking, new dependency, new package, or cache-semantics
  change) and the per-issue decision with rationale.
- GitHub labels `5.x` / `6.x` / `design-failure` created; all 11 open mirrored issues labelled.
- `DESIGN_FAILURES.md`: 13 findings, each with file and symbol evidence.

### D. Release (done in-tree; publish is human-triggered)

- `graphql_plus` 5.2.5 → **5.2.6**, finalizing the staged changelog section
  (`SocketClientConfig.getHeaders`).
- `graphql_flutter_plus` 5.3.1 → **5.3.2**, widened to `graphql_plus: ^5.2.6`.
- Local resolution before 5.2.6 is published: melos `usePubspecOverrides` +
  a gitignored `pubspec_overrides.yaml`. Must never be committed.

## Verification

| Check | Command | Expected |
| --- | --- | --- |
| Client analyze | `cd packages/graphql_plus && dart analyze --fatal-infos` | No issues found |
| Client tests | `cd packages/graphql_plus && dart test` | 123 passing |
| Widgets analyze (`lib/`) | `cd packages/graphql_flutter_plus && flutter analyze --fatal-infos` | 0 issues in `lib/` |
| Widgets tests | `cd packages/graphql_flutter_plus && flutter test` | 10 passing |
| Promo grep | `grep -ri "discord\|hiring\|expatfile\|opencollective\|laanwj" --include=*.md --include=*.yml .` | hits only in `CHANGELOG.md` |
| Relative links | every `../graphql*` / `./packages/*` target exists on disk | all resolve |
| Version/changelog match | `pubspec.yaml` version == top `CHANGELOG.md` heading | match for both packages |
| Publish readiness | `dart pub publish --dry-run`, `flutter pub publish --dry-run` | no blocking warnings |

## Risks

| Risk | Mitigation |
| --- | --- |
| Removing `example/` deprecations is tempting and expands scope | Explicitly out of scope; recorded as accepted |
| Committing `pubspec_overrides.yaml` would break other machines | Already gitignored by melos convention; rule re-added |
| A future Flutter makes a `lib/` import deprecated again | Analyze gate is per-package and fatal; it will catch it on CI |
| Upstream CHANGELOG references remain | Intentional provenance; documented in DESIGN_FAILURES "Accepted for 5.x" |