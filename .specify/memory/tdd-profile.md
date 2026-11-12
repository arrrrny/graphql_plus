# TDD Profile — graphql_plus

Detected: 2026-11-13. Every command below has been executed in this repository during the
sessions that produced `5.2.6` / `5.3.2` and the #3 / #15 fixes; none is copied from a
template.

## Stack

- **Language**: Dart 3.14.0 (stable) / Flutter 3.50.0 (stable)
- **Test runner**: `package:test` (`dart test`) for the client, `flutter_test` for the widgets
- **Monorepo**: Melos; per-package commands are run from the package directory
- **Analyzer**: `dart analyze` / `flutter analyze`, gate is `--fatal-infos`

## Commands

### Run one test by name (fastest red/green loop)

```
cd packages/graphql_plus && dart test test/<file>.dart --plain-name "<test name substring>"
```

Proven: used to isolate `SocketClient keepalive watchdog ...` and
`Partial optimistic writes ...`.

### Run one file

```
cd packages/graphql_plus && dart test test/<file>.dart
```

### Full client suite

```
cd packages/graphql_plus && dart test
```

Proven: 123 tests at 5.2.5, 128 after the #3 tests.

### Flutter widgets suite

```
cd packages/graphql_flutter_plus && flutter test
```

Proven: 10 tests.

### Analyze (the gate)

```
cd packages/graphql_plus && dart analyze --fatal-infos
cd packages/graphql_flutter_plus && flutter analyze --fatal-infos
```

Proven: both reach `No issues found!` on a clean tree.

### Format check

```
cd packages/graphql_plus && dart format --set-exit-if-changed .
```

### Coverage (client)

```
cd packages/graphql_plus && dart test --coverage=coverage
```

### Melos (whole monorepo)

```
dart pub global run melos run client_analyze --no-select
dart pub global run melos run client_test    --no-select
dart pub global run melos run flutter_analyze --no-select
dart pub global run melos run flutter_test   --no-select
```

Requires `dart pub global run melos bootstrap` once per clone.

## TDD principle for this repository

Test first, non-negotiable. A fix without a test that fails before and passes after is not
accepted; prove the red phase by reverting the change, not by asserting that it would have
failed.

## Known-flaky baseline

`test/observable_query_test.dart` poller tests and some `test/cancellable_http_link_test.dart`
cases fail intermittently on unmodified `master`; they carry hard
`timeout: Timeout(Duration(seconds: 1))`. A red result in those files must be re-run and
compared against a stashed tree before it is attributed to a change.