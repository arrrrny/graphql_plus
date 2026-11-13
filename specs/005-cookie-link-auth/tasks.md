# Tasks: First-class cookie-based authentication

**Spec**: [spec.md](./spec.md)

## Phase 0 — Establish the mechanism (before writing anything)

- [x] T001 Read how `AuthLink` injects a request header (`HttpLinkHeaders` context entry) and
      how `HttpLink` writes its response context (`HttpLinkResponseContext`) — the two hooks a
      cookie link needs already exist.
- [x] T002 Confirm the response context carries a *collapsed* header map: `package:http`
      joins repeated headers with `, `, so `Set-Cookie` arrives as one value. A plain
      `split(',')` would cut `Expires=Wed, 21 Oct 2015 …` in half.
- [x] T003 Record the finding: the parser must split only on a comma that starts a new
      `name=` pair, and `Expires` must be parsed with its leading weekday name or the cookie
      silently becomes a session cookie.

## Phase 1 — Red (tests first)

- [x] T004 `test/cookie_link_test.dart`: a cookie set by the first response is sent on the
      second (FR-001, FR-002)
- [x] T005 Test: `Credentials.omit` neither sends nor records (FR-004)
- [x] T006 Test: a custom `CookieStore` supplies the header and receives the response (FR-007)
- [x] T007 Test: an explicit `Cookie` header is not overwritten (FR-006)
- [x] T008 Test: several cookies set by one response are all recorded (FR-002)
- [x] T009 Test: an `Expires` value with a comma is one cookie, not two — the expired one is
      dropped rather than kept as a session cookie (FR-008)
- [x] T010 Test: a future `Expires` is kept (FR-008)
- [x] T011 Test: `Max-Age=0` deletes a stored cookie (FR-008)
- [x] T012 Test: a `Secure` cookie is not sent over http (FR-008)
- [x] T013 Test: `sameOrigin` ignores a cookie set by another origin; `include` sends it
      (FR-005)
- [x] T014 Test: the link composes over `CancellableHttpLink` as well as `HttpLink`

## Phase 2 — Green (implementation)

- [x] T015 Add `Credentials` (`omit` / `sameOrigin` / `include`) and the `CookieStore`
      contract with `cookieHeaderFor` / `addCookiesFromResponse` (FR-003, FR-007)
- [x] T016 Implement `InMemoryCookieStore` over a private `_Cookie` value: domain and path
      matching, `Secure`, `Max-Age`/`Expires`, expiry as deletion, replacement by
      name/domain/path, bounded size (FR-008)
- [x] T017 Implement `CookieLink.request` with `async*` + `await for`: inject the header on
      the way out, record `Set-Cookie` on the way back, propagate errors and cancellation
      (FR-001, FR-002)
- [x] T018 Split a joined `Set-Cookie` value with a comma-then-`name=` lookahead, and parse
      the weekday-prefixed HTTP date (Edge Cases)
- [x] T019 Export the new library from `links.dart` so `package:graphql_plus` surfaces it

## Phase 3 — Regression

- [x] T020 `dart format .` → clean
- [x] T021 `dart analyze --fatal-infos` → `No issues found!` (SC-002)
- [x] T022 `dart test test/cookie_link_test.dart` → 12/12 (SC-001)
- [x] T023 `dart test -j 2` → full client suite green (SC-003)
- [x] T024 `README.md`: document the link, the policy and the store seam (SC-004)
- [x] T025 `CHANGELOG.md`: record the additive entry and the 6.x deferral note (FR-009)

## Notes

- **The issue's first bullet is deferred, not skipped.** "Support `credentials`-style
  configuration on `HttpLink`" is a 6.x change:
  `../UPSTREAM_ISSUES_TRIAGE.md` records "a cookie link is additive but the `HttpLink` option
  is not", and constitution principle III forbids a 5.x signature change without a deferral
  note. This feature delivers the additive half — the link, with the same `credentials`
  vocabulary — and states the deferral in the PR body and the changelog.
- **Why the link takes the endpoint.** A `Link` cannot see the downstream URI, and cookie
  scoping needs a host. Every HTTP link in this ecosystem is constructed with its URI
  (`HttpLink(uri)`), so the caller already has the value.
- **`include` is deliberately broad.** It means "send every stored cookie", which is what an
  SSO cookie set by another origin requires. `sameOrigin` is the narrow default.