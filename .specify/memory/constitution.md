# GraphQL Plus Constitution

## Core Principles

### I. Test-First (NON-NEGOTIABLE)

Every behavioral change starts with a failing test. The red-green-refactor cycle is
mandatory: write the test that captures the desired behavior, watch it fail for the right
reason, then write the minimum production code to make it pass, then refactor under green.

- `graphql_plus` tests live in `packages/graphql_plus/test/`, run with `dart test`.
- `graphql_flutter_plus` tests live in `packages/graphql_flutter_plus/test/`, run with
  `flutter test`.
- A fix without a regression test is not a fix. Tests that cover a bug must fail on the
  pre-fix code — verified by reverting, not assumed.

### II. Clean Architecture Boundaries

Layer dependencies point inwards only: `presentation` (widgets/hooks) → `domain` (entities,
value objects, use cases, repository contracts) → `data` (link implementations, cache
adapters, HTTP/transport). No layer may import from a layer outside it.

- Domain code must not import `flutter`, `dart:io`, `http`, or any transport package.
- Cache, link, and transport details are adapters that implement domain contracts; the
  domain never imports an implementation.
- Widget code contains no transport or caching logic.

### III. Public API Compatibility in 5.x

The `5.x` line is a drop-in replacement for `package:graphql` 5.2.4 and
`package:graphql_flutter` 5.3.0. Until a major version is declared:

- No signature, default value, or exported-name changes without a deprecation period.
- Bug fixes are prioritized over API improvements.
- Anything that cannot be fixed without breaking the public API is deferred to `6.x` and
  recorded as such (see `UPSTREAM_ISSUES_TRIAGE.md`).

### IV. Fail Loud, Never Silently

A GraphQL client must never swallow an error into a silent no-op or an unhandled async
exception.

- Futures and stream controllers are completed exactly once; late arrivals are logged and
  dropped, never re-completed.
- Timeout, cancellation, and cache-miss paths surface a typed exception.
- `Bad state: Future already completed` and equivalent controller errors are treated as
  release-blocking defects.

### V. Simplicity and YAGNI

The smallest change that correctly solves the stated problem wins. No speculative
abstraction, no new dependency without a demonstrated need and an audit of its maintenance
status. Existing dependencies are not upgraded inside a patch release.

## Technology Constraints

- Dart SDK constraints are declared per-package in `pubspec.yaml`; do not widen a constraint
  in a patch release.
- Monorepo orchestration is Melos (`melos.yaml`). Do not hand-run per-package scripts that
  Melos already owns; prefer `make <target>`.
- Format with `dart format`; analysis must pass with `--fatal-infos`.
- `graphql_flutter_plus` depends on `graphql_plus`; a client change requires the widgets
  package to be re-tested, never only analyzed.

## Quality Gates

Before any change is called done:

1. `dart analyze --fatal-infos` clean for `graphql_plus`.
2. `dart test` green for `graphql_plus`.
3. `flutter analyze --fatal-infos` clean for `graphql_flutter_plus`.
4. `flutter test` green for `graphql_flutter_plus`.
5. Pre-existing failures are reported, not inherited silently — a red baseline must be
   named in the change description.
6. Public API changes are checked against `CHANGELOG.md` and the package version bump.

## Governance

This constitution supersedes convenience. Any PR or review must demonstrate compliance; a
deviation requires a written justification in the change description and, for principle
III, an explicit `6.x` deferral note.

Amendments require a documented rationale, a migration note for in-flight specs, and a
version bump of this file.

**Version**: 1.0.0 | **Ratified**: 2026-11-12 | **Last Amended**: 2026-11-12