# Feature Specification: First-class cookie-based authentication

**Feature Branch**: `005-cookie-link-auth`

**Created**: 2026-11-13

**Status**: Draft

**Input**: "Better cookie-based authentication support" —
https://github.com/arrrrny/graphql_plus/issues/7 (mirrors upstream
`graphql-flutter#592`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A login mutation is followed by an authenticated query (Priority: P1)

A user signs in through a mutation. The server answers with a session cookie. Every later
request in the same client carries that cookie, so the authenticated query that follows needs
no per-request work from the application.

**Why this priority**: it is the issue. Without a link that carries cookies, the application
has to read `Set-Cookie` off every response and re-inject the value by hand, which is the
"third-party cookie-jar workaround" the issue is about.

**Independent Test**: a server that sets `session=abc` on the first response and records the
`Cookie` header of the second; assert the second request carried `session=abc`.

**Acceptance Scenarios**:

1. **Given** a response carrying `Set-Cookie: session=abc`, **When** a second request is made
   through the same link, **Then** it carries `Cookie: session=abc`.
2. **Given** a request that already carries an explicit `Cookie` header, **When** the link
   runs, **Then** the explicit header is sent unchanged.

---

### User Story 2 - The caller controls which cookies flow (Priority: P1)

An application that talks to more than one origin, or that must not hold cookies at all, says
so once at construction instead of filtering by hand.

**Why this priority**: the fetch standard's `credentials` modes are the vocabulary users
already know, and the safe default must be the narrow one.

**Independent Test**: one store holding a cookie set by another origin; assert
`sameOrigin` (the default) sends nothing and `include` sends it; assert `omit` neither sends
nor records.

**Acceptance Scenarios**:

1. **Given** a cookie stored for `sso.example`, **When** the endpoint is `127.0.0.1` and the
   mode is the default `sameOrigin`, **Then** no `Cookie` header is sent.
2. **Given** the same store, **When** the mode is `include`, **Then** the cookie is sent.
3. **Given** the mode `omit`, **When** a response carries `Set-Cookie`, **Then** nothing is
   recorded and nothing is sent.

---

### User Story 3 - The jar is a seam, not a lock-in (Priority: P2)

An application that already keeps cookies somewhere (the `cookie_jar` package that dio uses,
for example) plugs that store in and the link uses it.

**Why this priority**: the store is the part an application is most likely to already own,
and re-implementing it inside the link would make the link unusable in that application.

**Independent Test**: a store whose `cookieHeaderFor` answers a fixed value and which records
the responses it is fed; assert the value is sent and the response reached the store.

**Acceptance Scenarios**:

1. **Given** a custom [CookieStore] answering `manual=1`, **When** a request runs, **Then**
   `Cookie: manual=1` is sent.
2. **Given** a response carrying `Set-Cookie`, **When** the link finishes it, **Then** the
   store's `addCookiesFromResponse` was called with the endpoint and those headers.

---

### Edge Cases

- **Repeated `Set-Cookie` headers.** `package:http` collapses them into one comma-joined
  value. A cookie whose `Expires` contains a comma (`Wed, 21 Oct 2015 07:28:00 GMT`) must not
  be split in half, and must not become an immortal session cookie when it was expired.
- **`Max-Age=0`.** This is how a server logs a session out; it must delete the stored cookie
  rather than store an empty one.
- **`Secure` over plain http.** The development server is `http://127.0.0.1`; a `Secure`
  cookie must not be sent to it, exactly as in a browser.
- **A cookie set by a host the link does not talk to.** The link is scoped to one endpoint,
  so it must not leak that cookie to a different origin.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `CookieLink` MUST send the stored cookies for its endpoint as a `Cookie` header
  on every request it forwards.
- **FR-002**: `CookieLink` MUST record the cookies a response carries and send them on later
  requests.
- **FR-003**: The link MUST expose a `Credentials` policy — `omit`, `sameOrigin`, `include` —
  defaulting to `sameOrigin`.
- **FR-004**: `omit` MUST neither send nor record cookies.
- **FR-005**: `sameOrigin` MUST confine the jar to the endpoint's host; `include` MUST send a
  cookie belonging to another origin.
- **FR-006**: An explicit `Cookie` header on the request MUST win over the store.
- **FR-007**: The store MUST be replaceable through a `CookieStore` contract, with an
  in-memory implementation provided.
- **FR-008**: The in-memory store MUST implement domain and path matching, `Secure`,
  `Max-Age`, `Expires` (including expiry as deletion), and replacement by
  name/domain/path.
- **FR-009**: The link MUST be additive to 5.x: no existing signature, default or export
  changes. The `credentials` option on `HttpLink` itself stays deferred to 6.x
  (see `../UPSTREAM_ISSUES_TRIAGE.md`).

### Key Entities

- **`Credentials`** — the cookie policy: `omit`, `sameOrigin`, `include`.
- **`CookieStore`** (contract) — read the cookies for a URI, record the cookies a response
  carries.
- **`InMemoryCookieStore`** — the default store.
- **`CookieLink`** — the link that applies the policy around a downstream HTTP link.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `packages/graphql_plus/test/cookie_link_test.dart` covers every acceptance
  scenario and passes.
- **SC-002**: `dart analyze --fatal-infos` is clean for `graphql_plus`.
- **SC-003**: The full `graphql_plus` suite is green, and `graphql_flutter_plus` is unaffected
  (the change is client-only and additive).
- **SC-004**: `README.md` documents the link, the policy and the store seam.

## Assumptions

- `package:http` collapses repeated response headers into one comma-joined value; the link
  parses that form. A transport that preserves raw headers is handled by the same parser,
  because each entry is parsed on its own.
- `SameSite` is not modelled: the link is not a browser and has no site context to apply it
  to. It is documented rather than silently ignored.
- The endpoint is known at construction, which is how every HTTP link in this ecosystem is
  built (`HttpLink(uri)`), so scoping the jar to it costs the caller nothing new.

## Out of Scope

- The `credentials` option on `HttpLink` itself. `../UPSTREAM_ISSUES_TRIAGE.md` records it as
  a 6.x change (the `HttpLink` option is not additive); this feature delivers the additive
  half, the link.
- Persisting the jar across process restarts.
- A `cookie_jar` package dependency: the seam is the contract, not a dependency
  (constitution principle V).