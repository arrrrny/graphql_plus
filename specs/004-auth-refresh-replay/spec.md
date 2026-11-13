# Feature Specification: Re-request an operation with updated auth context

**Feature Branch**: `004-auth-refresh-replay`

**Created**: 2026-11-13

**Status**: Draft

**Input**: "Re-request an operation with updated context (auth token refresh flow)" —
https://github.com/arrrrny/graphql_plus/issues/8 (mirrors upstream `graphql-flutter#220`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A link refreshes an expired token and replays the operation (Priority: P1)

An app's access token expires mid-session. A mutation fails. The link notices, fetches a new
token, and re-sends **the same operation** with the refreshed header. The caller sees one
successful result and never learns the first attempt failed.

**Why this priority**: it is the request. Without it, every token expiry is a user-visible
failure that the application must handle by hand, re-running the operation and reconciling
whatever partial state the first attempt left behind.

**Independent Test**: a server that rejects the first request with HTTP 401 and accepts the
second; assert the server saw two requests, the second carrying the new token, and that the
caller received the successful data.

**Acceptance Scenarios**:

1. **Given** a 401 on the first attempt, **When** `onAuthError` accepts it, **Then** the
   original operation is re-sent once with a freshly fetched token.
2. **Given** a successful replay, **When** the caller awaits the result, **Then** they receive
   the data and no error.
3. **Given** a non-auth failure (500, network), **When** it propagates, **Then** no replay is
   attempted unless `onAuthError` says otherwise.

---

### User Story 2 - The caller controls when a replay is worthwhile (Priority: P1)

Not every error means "refresh and retry". The caller decides by inspecting the error, and can
decline. When they decline, the original error surfaces unchanged.

**Why this priority**: a blind retry on every error turns a 500 into two 500s and can duplicate
mutations — the exact hazard of a retry loop.

**Independent Test**: `onAuthError: (_) => false` with a 401 first response; assert exactly one
request reached the server and the `HttpLinkServerException` reached the caller.

**Acceptance Scenarios**:

1. **Given** `onAuthError` returns `false`, **When** the first attempt fails, **Then** the error
   is re-thrown and no second request is made.
2. **Given** no `onAuthError` is configured, **When** the first attempt fails, **Then** the
   error is re-thrown and no second request is made.

---

### User Story 3 - A failing replay surfaces instead of looping (Priority: P1)

If the refreshed token is also rejected, the caller gets the second error. The link never
retries more than once.

**Why this priority**: an unbounded retry on an auth failure is a self-inflicted outage — and for
a mutation, a duplicate write.

**Independent Test**: both responses are 401; assert exactly two requests reached the server and
the caller received an exception.

**Acceptance Scenarios**:

1. **Given** two consecutive 401s, **When** the operation runs, **Then** exactly two requests
   are made and the second error surfaces.

---

### Edge Cases

- **A token that does not change.** If `getToken` returns the same value, the replay is
  pointless but harmless; the caller's `onAuthError` should decline in that case.
- **A non-HTTP failure** (socket error, timeout) — replay is allowed only if `onAuthError`
  accepts it, which for most callers it will not.
- **A request whose context already carries other entries** — the replay must preserve them and
  only replace the auth header.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `AuthLink` MUST accept an optional `onAuthError` callback that decides whether a
  downstream error warrants a refresh-and-replay.
- **FR-002**: When `onAuthError` accepts, `AuthLink` MUST fetch a new token via `getToken` and
  re-send the **original** operation with the refreshed header.
- **FR-003**: `AuthLink` MUST replay at most once; a second failure MUST surface to the caller.
- **FR-004**: When `onAuthError` is absent or declines, the original error MUST be re-thrown
  unchanged and no replay MUST occur.
- **FR-005**: The replay MUST preserve every other context entry on the request.
- **FR-006**: Existing `AuthLink` behaviour — adding `headerKey: getToken()` to every request —
  MUST be unchanged, and `onAuthError` MUST be optional (no breaking change).

### Key Entities

- **`AuthLink`** — header-injecting link, now optionally refresh-and-replay capable.
- **`HttpLinkHeaders`** — the request context entry the header is written into.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A 401-then-200 server sees exactly two requests, the second with the new token,
  and the caller receives data (no error).
- **SC-002**: A declined refresh produces exactly one request and a thrown
  `HttpLinkServerException`.
- **SC-003**: Two consecutive 401s produce exactly two requests and a thrown exception.
- **SC-004**: `dart analyze --fatal-infos` is clean and the existing suite passes.

## Assumptions

- Replay is attempted only for errors surfaced as exceptions by the downstream link. A `200`
  response carrying a GraphQL `errors` body is delivered as a `Response`, not an exception, and
  is therefore not replayed by this mechanism.
- The caller's `onAuthError` is responsible for recognising the auth condition; the link does not
  parse status codes on the caller's behalf.
- One replay is enough; a second refresh would risk duplicating a mutation.

## Out of Scope

- Automatic token expiry parsing (JWT `exp`) or proactive refresh before a request.
- Refresh-token rotation and persisting the new token — that is the application's job.
- Retrying non-auth failures or adding backoff.

## Implementation note (non-obvious)

`AuthLink` must forward with `await for`, not `yield*`. Inside an `async*` generator the error
from a `yield*`-ed stream is delivered to the downstream listener rather than thrown at the
`yield*`, so a surrounding `try`/`catch` never sees it and any replay in the `catch` block is
dead code. This was measured directly: the same link caught the error and replayed successfully
with `await for`, and let it escape with `yield*`.