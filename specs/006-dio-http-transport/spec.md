# Feature Specification: dio as an HTTP transport

**Feature Branch**: `006-dio-http-transport`

**Created**: 2026-11-14

**Status**: Draft

**Input**: "Support dio as an http transport" —
https://github.com/arrrrny/graphql_plus/issues/13 (mirrors upstream
`graphql-flutter#712`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A dio-using app shares one HTTP stack (Priority: P1)

An application already uses dio for REST: a token-refresh interceptor, an error
logger, a timeout policy and a cookie jar. It adds GraphQL and does not want a
second HTTP stack, a second copy of those interceptors or a second cookie jar.

**Why this priority**: it is the issue. Without a dio-backed link, the GraphQL
transport is `package:http` while every other call goes through dio, so an
auth-refresh fix has to be written twice and the two stacks can disagree about
timeouts, proxies and cookies.

**Independent Test**: a `Dio` carrying an interceptor that adds a header; a query
through `DioLink(client: thatDio)`; assert the server saw the header.

**Acceptance Scenarios**:

1. **Given** a `Dio` whose interceptor adds `x-intercepted: yes`, **When** a query
   runs through a `DioLink` built with that client, **Then** the endpoint receives
   the header.
2. **Given** a `Dio` with `connectTimeout`/`receiveTimeout` in its `BaseOptions`,
   **When** the endpoint answers too slowly, **Then** the operation fails with a
   link exception rather than hanging.
3. **Given** a `Dio` the link did not create, **When** the link is disposed,
   **Then** the client is still usable.

---

### User Story 2 - The transport is interchangeable (Priority: P1)

An application moves from `HttpLink` to `DioLink` (or back) without touching its
error handling, its upload code or its cancellation code.

**Why this priority**: the value of a second transport is that it is a
construction-time choice. If the exceptions, the multipart shape or the
cancellation semantics differ, every call site that inspects a failure has to be
re-written.

**Independent Test**: the same operation against a 503 endpoint, a 200 endpoint
carrying GraphQL `errors`, and an unparseable body, on both links.

**Acceptance Scenarios**:

1. **Given** a response with status 503, **When** either link runs, **Then** the
   error is an `HttpLinkServerException` carrying that status code.
2. **Given** a 200 response whose body is not a JSON object, **When** either link
   runs, **Then** the error is an `HttpLinkParserException`.
3. **Given** a 200 response carrying GraphQL `errors`, **When** either link runs,
   **Then** the response carries those errors and no exception is thrown.

---

### User Story 3 - Cancel and upload behave as they do on `HttpLink` (Priority: P2)

The client's `CancellationToken` aborts a request in flight and the documented
multipart upload format still works.

**Why this priority**: these two are the `graphql` features a dio transport could
silently lose — a cancelled request that keeps running, or an upload that stops
being the GraphQL multipart request.

**Independent Test**: a slow endpoint and a cancelled token; a `Upload` mutation
with an `http.MultipartFile` variable.

**Acceptance Scenarios**:

1. **Given** an operation started with a `CancellationToken`, **When** the token is
   cancelled before the response, **Then** the operation fails with
   `CancelledException`.
2. **Given** variables carrying an `http.MultipartFile`, **When** the mutation runs
   through `DioLink`, **Then** the request is `multipart/form-data` with
   `operations`, `map` and one part per file.
3. **Given** `useGETForQueries`, **When** a query runs, **Then** it is a GET with
   the operation in the query string, and a mutation is still a POST.

---

### User Story 4 - Cookies work on either transport (Priority: P3)

`CookieLink` carries the session cookies the server sets in front of whichever
terminating link is used, and a dio cookie interceptor covers the same ground for
an app that already has one.

**Why this priority**: it is the second half of the "share the client" promise —
the transport choice must not decide whether a session-cookie flow works.

**Independent Test**: `CookieLink(uri: …)` in front of `DioLink`; a first response
that sets `session=abc`; assert the second request carries it.

**Acceptance Scenarios**:

1. **Given** a response setting `session=abc`, **When** a second request goes
   through `CookieLink` → `DioLink`, **Then** it carries `Cookie: session=abc`.

## Requirements

### Functional Requirements

- **FR-001**: `DioLink` MUST execute a GraphQL operation over HTTP through dio and
  yield the parsed `Response`.
- **FR-002**: `DioLink` MUST accept a caller-supplied `Dio` and send through it
  unchanged, so interceptors, `BaseOptions` timeouts and cookie managers apply.
- **FR-003**: A `Dio` the link did not create MUST NOT be closed by `dispose()`; a
  `Dio` the link created MUST be.
- **FR-004**: A non-2xx status, or a 2xx response missing both `data` and `errors`,
  MUST raise `HttpLinkServerException` with the status code.
- **FR-005**: A body that cannot be parsed MUST raise `HttpLinkParserException`.
- **FR-006**: A 200 response carrying GraphQL `errors` MUST be delivered as a
  `Response` with those errors, not thrown.
- **FR-007**: `useGETForQueries` MUST send queries as GET with the operation encoded
  in the query string, and mutations as POST.
- **FR-008**: `defaultHeaders` and the per-request `HttpLinkHeaders` MUST both be
  applied, request headers winning.
- **FR-009**: The response context MUST carry `HttpLinkResponseContext` with the
  status code and headers.
- **FR-010**: A `CancellationToken` in the request context MUST abort the in-flight
  exchange and surface `CancelledException`.
- **FR-011**: Variables carrying an `http.MultipartFile` MUST be sent as the GraphQL
  multipart request (`operations`, `map`, one part per file).
- **FR-012**: `DioLink` MUST compose with `CookieLink` and with the rest of the link
  chain, and MUST NOT change an existing signature, default or export.
- **FR-013**: The README MUST say when to choose dio and when to choose `http`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An application using dio for REST adds GraphQL with one link
  construction and no second interceptor, timeout or cookie policy.
- **SC-002**: Every `HttpLink` exception type is produced by `DioLink` for the same
  server responses, so no call site changes with the transport.
- **SC-003**: The package's own suite is green with the link in-tree, and the link
  has tests for each acceptance scenario above.