# Tasks: Re-request an operation with updated auth context

**Spec**: [spec.md](./spec.md)

## Phase 0 — Establish the mechanism (before writing anything)

- [x] T001 Write a throwaway link that catches an auth error and re-forwards the operation
- [x] T002 Observe that `try { yield* forward!(request); } catch` does **not** catch — the
  `HttpLinkServerException` escapes to the listener
- [x] T003 Re-run with `try { await for (final r in forward!(request)) { yield r; } } catch` —
  the error is caught, the replay runs, and the server records
  `serverHits=2 auth=[<none>, Bearer fresh]` with `result.data={viewer: {id: 1}}`
- [x] T004 Record the finding: replay is mechanically supported; the blocker is the `yield*`
  form silently swallowing the catch

## Phase 1 — Red (tests first)

- [x] T005 `test/auth_link_test.dart`: `AuthLink` adds the token header to every request (existing behaviour)
- [x] T006 Test: a 401 first response is replayed with a freshly minted token (FR-001, FR-002)
- [x] T007 Test: the refresh callback can mint a new token between attempts (FR-002)
- [x] T008 Test: a declined refresh re-throws and does not replay (FR-004)
- [x] T009 Test: no `onAuthError` configured → re-throw, no replay (FR-004)
- [x] T010 Test: two consecutive 401s → exactly two requests, second error surfaces (FR-003)

## Phase 2 — Green (implementation)

- [x] T011 Add optional `onAuthError` to `AuthLink`; make it a `Link` directly (drop the private
  `_AsyncReqTransformLink` base, which forced `yield*`)
- [x] T012 Extract `_withToken` so both the first attempt and the replay build the header the
  same way, preserving other context entries (FR-005)
- [x] T013 Forward with `await for` and document why `yield*` is wrong, in a code comment
- [x] T014 Re-throw when `onAuthError` is absent or returns false (FR-004)
- [x] T015 Replay at most once (FR-003)

## Phase 3 — Regression

- [x] T016 `dart analyze --fatal-infos` → No issues found! (FR-006, SC-004)
- [x] T017 `dart test test/auth_link_test.dart` → 6/6 (SC-001..SC-003)
- [x] T018 `dart test` → 128 pass; the only failure is the pre-existing
  `observable_query_test.dart: can start poller` flake (see `.specify/memory/tdd-profile.md`)
- [x] T019 `dart format --set-exit-if-changed .` → clean

## Notes

- FR-006 holds: `onAuthError` is a new *optional* named parameter. `AuthLink(getToken: ...)` is
  still valid and behaves exactly as before.
- The test server needed distinct status codes: a `200` with a GraphQL `errors` body is emitted
  as a `Response`, not thrown, so the auth-failure cases use HTTP 401. That distinction is
  recorded in the spec's Assumptions and is why the first draft of the tests passed for the
  wrong reason.