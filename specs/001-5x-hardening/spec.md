# Feature Specification: Harden the 5.x line and audit it for the 6.x rewrite

**Feature Branch**: `001-5x-hardening`

**Created**: 2026-11-12

**Status**: Draft

**Input**: Fork housekeeping + hardening of `graphql_plus` 5.2.6 / `graphql_flutter_plus`
5.3.2, plus an evidence-backed design-failure audit that feeds the 6.x clean-architecture
rewrite.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A fork that looks like a fork (Priority: P1)

A visitor lands on the repository or on either pub.dev page. They see this project's name,
this project's badges, and links that resolve. They are not shown another company's hiring
banner, another project's Discord, another repository's CI badge, or a donation gallery that
has nothing to do with this fork.

**Why this priority**: Everything else is invisible if the front door advertises a dead
upstream. It is also the cheapest possible win — no code risk, and it is what a new
contributor or adopter reads first.

**Independent Test**: `grep -ri "discord|hiring|expatfile|opencollective|laanwj"` over the
tracked Markdown and YAML returns nothing outside `CHANGELOG.md`. Every relative link in
both READMEs is resolved with `markdown-link-check` or a manual path existence check.

**Acceptance Scenarios**:

1. **Given** a clean checkout, **When** the promo patterns are searched for, **Then** the
   only remaining hits are historical CHANGELOG entries.
2. **Given** a relative link such as `./packages/graphql/README.md`, **When** the file is
   checked on disk, **Then** it exists (it must point at `packages/graphql_plus`).

---

### User Story 2 - Analyze and test are green on a clean checkout (Priority: P1)

A contributor clones the repo, runs the documented check command, and gets a green result on
first try, without having to guess which pre-existing failure is theirs.

**Why this priority**: A red baseline makes every later change unverifiable. It is the
precondition for TDD on this repository.

**Independent Test**: `dart analyze --fatal-infos` and `dart test` in `packages/graphql_plus`;
`flutter analyze --fatal-infos` and `flutter test` in `packages/graphql_flutter_plus`.

**Acceptance Scenarios**:

1. **Given** the master branch, **When** `dart analyze --fatal-infos` runs in
   `packages/graphql_plus`, **Then** zero issues are reported.
2. **Given** the master branch, **When** `flutter analyze --fatal-infos` runs in
   `packages/graphql_flutter_plus`, **Then** zero issues are reported **for `lib/`**.
3. **Given** the master branch, **When** `dart test` / `flutter test` run, **Then** every
   test passes.

---

### User Story 3 - Every transferred upstream issue has a release-line decision (Priority: P1)

Someone reading `UPSTREAM_ISSUES_TRIAGE.md` can tell, for each mirrored issue, whether it
lands on `5.x` or `6.x`, and why. The same decision is visible on GitHub as a label.

**Why this priority**: Without a decision, the backlog becomes a second copy of the upstream
graveyard this fork exists to escape.

**Independent Test**: Every open issue carries exactly one of the `5.x` / `6.x` labels, and
the tables in `UPSTREAM_ISSUES_TRIAGE.md` match the labels one-to-one.

**Acceptance Scenarios**:

1. **Given** the 11 open mirrored issues, **When** the labels are listed, **Then** each has
   exactly one release-line label.
2. **Given** a reader asks "why is this not in 5.x?", **When** they read the triage table,
   **Then** a stated reason exists (breaking change, new dependency, new package, or cache
   semantics change).

---

### User Story 4 - A written design-failure audit that the 6.x rewrite must satisfy (Priority: P1)

An engineer starting the 6.x rewrite can read one document and know which parts of the 5.x
architecture are load-bearing and which are accidents of history, with file-level evidence.

**Why this priority**: The rewrite is only worth doing if it is aimed at real failures. A
vague "modernize it" brief produces a rewrite that reproduces the same defects.

**Independent Test**: Every finding in `DESIGN_FAILURES.md` names the file(s) and symbol(s)
that exhibit it, and every finding is either mapped to a 6.x requirement or explicitly
recorded as accepted.

**Acceptance Scenarios**:

1. **Given** a finding, **When** it is read, **Then** it cites a concrete path and symbol.
2. **Given** the audit, **When** the 6.x spec is written, **Then** each finding has a
   corresponding design decision or an explicit non-goal.

---

### User Story 5 - The 5.x release is published and reproducible (Priority: P2)

A user can install `graphql_plus` 5.2.6 and `graphql_flutter_plus` 5.3.2 from pub.dev, and
the tagged commit is exactly the code that was published.

**Why this priority**: Real work that nobody can install is not delivered. But it depends on
stories 1-2 being true first.

**Independent Test**: `dart pub publish --dry-run` and `flutter pub publish --dry-run` in
each package; the git tag resolves to the publishing commit; the CHANGELOG's top entry
matches the published version.

**Acceptance Scenarios**:

1. **Given** the release commit, **When** `dart pub publish --dry-run` runs, **Then** it
   reports no warnings that would block publication.
2. **Given** a user adds `graphql_plus: ^5.2.6`, **When** `dart pub get` runs, **Then** it
   resolves against the published 5.2.6.

---

### Edge Cases

- **A local `graphql_plus` ahead of the published one.** `graphql_flutter_plus` pins
  `graphql_plus: ^5.2.6`; until 5.2.6 is on pub.dev, `flutter pub get` fails for a fresh
  clone. Mitigation in place: melos `usePubspecOverrides` plus a gitignored
  `pubspec_overrides.yaml`. The override must not be committed.
- **A Flutter version that deprecates `material.dart`.** On Flutter 3.47.0+ the deprecated
  import is an `info`, and `--fatal-infos` promotes it to a failure. This affects
  `example/` and `test/` today and is deliberately out of scope for a patch release.
- **An issue that is half-fixable.** Some upstream reports (auth refresh) are partly
  addressed by an additive API and partly blocked on a breaking change. The triage records
  them as "partial" rather than forcing a binary.
- **A deleted upstream issue.** The triage table cites upstream issue numbers; if upstream
  prunes them, the fork-side number remains authoritative.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The repository's user-facing documentation MUST NOT reference the upstream
  project's Discord, hiring, or sponsorship channels, or any badge belonging to a different
  repository.
- **FR-002**: Every relative documentation link MUST resolve against the current package
  directory names.
- **FR-003**: `dart analyze --fatal-infos` MUST report zero issues for `packages/graphql_plus`.
- **FR-004**: `flutter analyze --fatal-infos` MUST report zero issues for the `lib/` tree of
  `packages/graphql_flutter_plus`.
- **FR-005**: The full test suite of both packages MUST pass on the release commit.
- **FR-006**: Every open mirrored issue MUST carry exactly one release-line label (`5.x` or
  `6.x`) and a recorded rationale.
- **FR-007**: Each published package's `CHANGELOG.md` MUST have a top entry matching the
  version in its `pubspec.yaml`.
- **FR-008**: `graphql_flutter_plus` MUST declare a `graphql_plus` constraint satisfiable by
  the released client version, and MUST be testable locally before that version is published
  (via a non-committed override).
- **FR-009**: The design-failure audit MUST cite concrete files and symbols for every
  finding.
- **FR-010**: The 6.x specification MUST reference every audit finding and state how it is
  resolved, deferred, or accepted.
- **FR-011**: No public API in `5.x` may change in a way that breaks a downstream caller
  without a deprecation cycle (constitution principle III).
- **FR-012**: Any fix that cannot meet FR-011 MUST be recorded as a `6.x` deferral with a
  link from the triage document.

### Key Entities

- **Mirrored issue**: a fork-side GitHub issue tracking an upstream report. Attributes: fork
  number, upstream number, release-line decision, rationale, state.
- **Design failure**: an architectural defect in 5.x. Attributes: id, symptom, evidence
  (paths + symbols), blast radius, 6.x resolution status.
- **Release**: a versioned pair (`graphql_plus`, `graphql_flutter_plus`). Attributes:
  versions, changelog entries, tag names, publish state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero promo/community references outside `CHANGELOG.md` (measured by the grep
  in User Story 1's independent test).
- **SC-002**: Zero analyzer issues in `packages/graphql_plus` and in `packages/graphql_flutter_plus/lib`.
- **SC-003**: 100% of the 5.x test suite passing (123 client tests, 10 widget tests at the
  time of writing).
- **SC-004**: 11 of 11 open mirrored issues labelled with a release line.
- **SC-005**: Every design failure in the audit maps to at least one requirement or explicit
  non-goal in the 6.x spec.
- **SC-006**: Both packages pass `pub publish --dry-run` from the release commit.

## Assumptions

- The `5.x` line must remain a drop-in replacement for `package:graphql` 5.2.4 and
  `package:graphql_flutter` 5.3.0; breaking changes belong to `6.x`.
- No new runtime dependency is added to `5.x`.
- Publishing is a human-triggered action (git tag + GitHub release), not something the agent
  performs.
- The Flutter-version-specific `deprecated_member_use` infos in `example/` and `test/` are a
  Material-migration concern and are accepted for this release.
- The Zuraffa (`zfa`) toolchain is the intended code-generation and architecture substrate
  for `6.x`; `5.x` stays hand-maintained.
- Upstream issue numbers remain resolvable as historical references even if upstream deletes
  them.

## Out of Scope

- Implementing the four `5.x` fixes themselves (they are separate specs).
- Any API addition beyond what already shipped in 5.2.6.
- Migrating `example/` and `test/` off `package:flutter/material.dart`.
- Upgrading existing dependencies (`package-upgrades` is explicitly excluded from patch
  releases by the constitution).