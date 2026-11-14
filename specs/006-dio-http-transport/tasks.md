# Tasks: dio as an HTTP transport

**Spec**: [spec.md](./spec.md)

## Phase 0 — Establish the mechanism (before writing anything)

- [x] T001 Read `gql_dio_link` 2.0.0 as the reference: it ships a `Link` over dio with
      `endpoint`/`client`/`serializer`/`parser`/`useGETForQueries`, a `CancelToken`
      context entry, and its own exception family.
- [x] T002 Read the in-tree precedent: `CancellableHttpLink` is a vendored
      `gql_http_link` that adds cancellation and documents itself as "keep in sync with
      `HttpLink`". The dio link follows that shape rather than `gql_dio_link`'s exception
      family, so both transports surface the same errors.
- [x] T003 Confirm dio 5.x is compatible: sdk `>=2.18.0 <4.0.0`, and every dependency is
      already inside `graphql`'s constraints.
- [x] T004 Record the decision: `validateStatus: (status) => true` on the request options,
      so the status check stays in the link and a 4xx/5xx reaches
      `HttpLinkServerException` instead of a `DioException`.

## Phase 1 — Red (tests first)

- [x] T005 `test/dio_link_test.dart`: an operation executes and parses (FR-001)
- [x] T006 Test: a caller-supplied `Dio`'s interceptor reaches the endpoint (FR-002)
- [x] T007 Test: `dispose()` leaves a caller-supplied client usable and closes a client it
      created (FR-003)
- [x] T008 Test: `useGETForQueries` sends a query as GET and a mutation as POST (FR-007)
- [x] T009 Test: `defaultHeaders` and request headers are both applied (FR-008)
- [x] T010 Test: the response context carries the status code and headers (FR-009)
- [x] T011 Test: a 503 is an `HttpLinkServerException` (FR-004)
- [x] T012 Test: a 200 with GraphQL `errors` is delivered, not thrown (FR-006)
- [x] T013 Test: an unparseable body is an `HttpLinkParserException` (FR-005)
- [x] T014 Test: a cancelled token yields `CancelledException` (FR-010)
- [x] T015 Test: a transport failure surfaces as a link exception, not a hang (FR-001)
- [x] T016 Test: an `http.MultipartFile` variable sends the GraphQL multipart request
      (FR-011)
- [x] T017 Test: `CookieLink` → `DioLink` sends the cookie the first response set (FR-012)
- [x] T018 Test: a shared client's own `BaseOptions` configuration reaches the endpoint

## Phase 2 — Green (implementation)

- [x] T019 Add `dio: ^5.9.0` to `packages/graphql_plus/pubspec.yaml`
- [x] T020 Implement `DioLink` in `lib/src/links/dio_link/dio_link.dart`: `uri`, `client`,
      `defaultHeaders`, `useGETForQueries`, `serializer`, `parser`, `responseDecoder`
- [x] T021 Map request context → dio: `HttpLinkHeaders` into the request headers, and
      `CancellationContextEntry` onto a `CancelToken` with the listener released when the
      exchange ends
- [x] T022 Bridge `http.MultipartFile` variables to `dio.MultipartFile` and build the
      `operations`/`map`/file parts body
- [x] T023 Map the outcomes: `CancelledException` for a cancel, `HttpLinkServerException`
      for a non-2xx or an empty response, `HttpLinkParserException` for a parse failure,
      `ServerException` for a transport failure
- [x] T024 Export the link from `lib/src/links/links.dart`

## Phase 3 — Document

- [x] T025 README: "Choosing an HTTP transport: dio or http", with the interceptor/timeout
      example and the when-to-use list (FR-013)
- [x] T026 README links intro names `DioLink` alongside the other in-tree links
- [x] T027 CHANGELOG: the `DioLink` entry, including that `dio` is a new runtime dependency