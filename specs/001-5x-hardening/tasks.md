# Tasks: Harden the 5.x line and audit it for the 6.x rewrite

**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Status legend: `[x]` done in commit `4eee571` · `[ ]` outstanding

## Phase 1 — Documentation and metadata (US1)

- [x] T001 Remove the "We're Hiring!" banner and OpenCollective gallery from `README.md`
- [x] T002 Remove the Discord badge and all `[discord-*]` link definitions from `README.md`
- [x] T003 Remove the `laanwj/rust-clightning-rpc` CI badge, upstream pub/coverage/license
  badges, and GitHub watchers/stars definitions from `README.md`
- [x] T004 Repoint 7 `./packages/graphql/README.md` links to `./packages/graphql_plus/README.md`
- [x] T005 Rewrite the header block of `packages/graphql_plus/README.md` for the fork
- [x] T006 Rewrite the header block of `packages/graphql_flutter_plus/README.md` for the fork
- [x] T007 Remove Discord and upstream badges from both package READMEs; repoint 11 relative
  links to `../graphql_plus/README.md`
- [x] T008 Replace the Discord contact line in `CONTRIBUTING.md` and `.github/ISSUE_TEMPLATE/bug_report.md`
- [x] T009 Remove `open_collective: graphql-flutter` from `.github/FUNDING.yml`
- [x] T010 Verify no promo pattern survives outside `CHANGELOG.md`

## Phase 2 — Green baseline (US2)

- [x] T011 Move `cache_provider.dart` off `package:flutter/material.dart`
- [x] T012 Move `hive_init.dart` off `package:flutter/material.dart`
- [x] T013 Confirm `flutter analyze --fatal-infos` reports zero issues under `lib/`
- [x] T014 Record the 9 remaining `example/`+`test/` deprecations as accepted scope

## Phase 3 — Triage (US3)

- [x] T015 Add the "Triage decisions — 5.x vs 6.x" section to `UPSTREAM_ISSUES_TRIAGE.md`
- [x] T016 Create the `5.x`, `6.x` and `design-failure` GitHub labels
- [x] T017 Label all 11 open mirrored issues (4 → `5.x`, 7 → `6.x`)

## Phase 4 — Design-failure audit (US4)

- [x] T018 Write `DESIGN_FAILURES.md` with 13 findings and file/symbol evidence
- [x] T019 Map each finding to a 5.x action and a 6.x action

## Phase 5 — Release (US5)

- [x] T020 Finalize the `v5.2.6` changelog section in `packages/graphql_plus/CHANGELOG.md`
- [x] T021 Add the `v5.3.2` entry in `packages/graphql_flutter_plus/CHANGELOG.md`
- [x] T022 Bump both `pubspec.yaml` versions and widen the `graphql_plus` constraint
- [x] T023 Add a gitignored `pubspec_overrides.yaml` so the widgets package resolves locally
- [x] T024 Re-run analyze + tests on the bumped tree
- [x] T025 Ignore `.kimi-code/` and `**/pubspec_overrides.yaml`
- [x] T026 Commit with a conventional-commit message

## Phase 6 — Quality gate (DF-13)

- [x] T027 Fix `Makefile` `ci_fmt_flutter` to run `flutter_analyze` instead of `client_analyze`
- [x] T028 Replace the removed `dart pub run test` with `dart test` in `melos.yaml`
- [x] T029 Scope `flutter_analyze` to `graphql_flutter_plus` so the `app` example package does not gate it
- [x] T030 Exclude `example/**` from the package analyzer; ignore `deprecated_member_use` on the three test imports
- [x] T031 Verify all four gates green through melos: `client_analyze`, `client_test`, `flutter_analyze`, `flutter_test`
- [x] T032 Update `DESIGN_FAILURES.md` (DF-13 marked resolved) and record the analysis change in the widgets CHANGELOG

## Phase 7 — Outstanding (follow-up specs, not this one)

- [ ] T033 `dart pub publish --dry-run` for `graphql_plus` 5.2.6 (requires the publish
  credentials; human-triggered)
- [ ] T034 `flutter pub publish --dry-run` for `graphql_flutter_plus` 5.3.2
- [ ] T035 Tag `graphql_plus-v5.2.6` and `graphql_flutter_plus-v5.3.2` and cut GitHub releases
  (the release workflows listen for these tags)
- [ ] T036 Spec + implement the four `5.x`-labelled issues: #15, #3, #6, #8