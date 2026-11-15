#!/usr/bin/env bash
# Integration tests for scripts/release.sh (issue #41).
#
# release.sh is exercised END TO END in a throwaway git repo whose PATH is
# shimmed: curl serves a fake pub.dev API from state files, dart/flutter/gh
# record their invocations and follow the same state, so a run needs no
# network, no pub.dev credential, and publishes nothing. The two behaviours
# under test are the ones issue #41 reported:
#
#   1. the post-client wait must poll RESOLVABILITY (pub actually serving the
#      version to pub get), not the API `latest` field — which flips the moment
#      an upload is accepted, before `flutter pub publish --dry-run` can resolve
#      the new client constraint;
#   2. `--local` must be RESUMABLE: a client version that is already on pub.dev
#      is a skip-and-continue point, not a preflight death.
#
# The shims key off a state dir (exported as RELEASE_TEST_STATE):
#   state/client-published   created by the dart shim on `pub publish --force`;
#                            pre-create it to simulate a half-finished release
#   state/flutter-published  created by the flutter shim on `publish --force`
#   state/probe-resolvable   created by the dart shim the first time the
#                            resolvability probe (`dart pub get` in the probe
#                            package) runs after the client is published —
#                            the stand-in for pub.dev finishing its indexing
#   state/dart.log, state/flutter.log   invocation records the tests assert on
#
# The `flutter pub publish --dry-run` shim FAILS in registry-resolved mode
# (no pubspec_overrides.yaml in cwd) unless probe-resolvable exists: that is
# the incident's failure, reproduced — a dry run that races indexing dies with
# "version solving failed" exactly as reported in #41.
#
#   ./scripts/release_test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="$ROOT/scripts/release.sh"
CLIENT_VERSION="$(awk '/^version:[[:space:]]*/ { print $2; exit }' "$ROOT/packages/graphql_plus/pubspec.yaml")"
FLUTTER_VERSION="$(awk '/^version:[[:space:]]*/ { print $2; exit }' "$ROOT/packages/graphql_flutter_plus/pubspec.yaml")"

CURRENT_SANDBOX=""
cleanup() {
  if [ -n "$CURRENT_SANDBOX" ]; then
    rm -rf "$CURRENT_SANDBOX"
    CURRENT_SANDBOX=""
  fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# ------------------------------------------------------------------ shims

write_shims() {
  local bin="$1"
  # curl: the pub.dev API, served from the state dir. `latest` flips to the
  # released version the moment the shimmed client publish happens — the
  # accept-time flip that makes the API field a lying readiness signal (#41).
  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${RELEASE_TEST_STATE:?}"
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  *"/api/packages/graphql_flutter_plus"*) name="flutter" ;;
  *"/api/packages/graphql_plus"*) name="client" ;;
  *) echo "curl shim: unexpected url: $url" >&2; exit 22 ;;
esac
client_latest="1.0.0"
[ -e "$STATE/client-published" ] && client_latest="$CLIENT_VERSION"
flutter_latest="1.0.0"
[ -e "$STATE/flutter-published" ] && flutter_latest="$FLUTTER_VERSION"
# The script reads pub.dev fail-closed (`curl -w '\n%{http_code}'`): it needs
# the JSON body AND the status line, so emit both — the fake API answers 200.
if [ "$name" = "client" ]; then
  printf '{"latest":{"version":"%s"}}\n200\n' "$client_latest"
else
  printf '{"latest":{"version":"%s"}}\n200\n' "$flutter_latest"
fi
EOF
  # dart: records invocations; `pub publish --force` marks the client shipped;
  # `pub get` in the probe package is the resolvability probe — it fails until
  # the client is published, and on its first success flips probe-resolvable
  # (pub.dev finished indexing).
  cat >"$bin/dart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${RELEASE_TEST_STATE:?}"
log() { printf '%s\n' "$*" >>"$STATE/dart.log"; }
case "$1 $2" in
  "pub token")
    echo "https://pub.dev" ;;
  "pub publish")
    case "${3:-}" in
      --dry-run) log "client publish --dry-run"; exit 0 ;;
      --force)
        touch "$STATE/client-published"
        log "client publish --force"
        exit 0
        ;;
      *) exit 1 ;;
    esac ;;
  "pub get")
    if [ -f pubspec.yaml ] && grep -q "name: release_resolvability_probe" pubspec.yaml; then
      if [ -e "$STATE/client-published" ]; then
        touch "$STATE/probe-resolvable"
        log "resolvability probe OK"
        exit 0
      fi
      log "resolvability probe FAIL"
      echo "Because release_resolvability_probe depends on graphql_plus ^$CLIENT_VERSION which doesn't match any versions, version solving failed." >&2
      exit 1
    fi
    exit 0 ;;
  *)
    log "dart $*"
    exit 0 ;;
esac
EOF
  # flutter: the local validation (throwaway copy with pubspec_overrides.yaml)
  # always passes; the registry-resolved dry run passes ONLY once the probe
  # succeeded — reproduce #41's "version solving failed" if the release script
  # raced indexing instead of waiting for resolvability.
  cat >"$bin/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${RELEASE_TEST_STATE:?}"
log() { printf '%s\n' "$*" >>"$STATE/flutter.log"; }
case "$*" in
  *"pub publish --dry-run"*)
    if [ -f pubspec_overrides.yaml ]; then
      log "flutter local-validation dry-run (override copy)"
      exit 0
    fi
    if [ -e "$STATE/probe-resolvable" ]; then
      log "flutter registry dry-run OK"
      exit 0
    fi
    log "flutter registry dry-run FAIL (raced indexing)"
    echo "Because graphql_flutter_plus depends on graphql_plus ^$CLIENT_VERSION which doesn't match any versions, version solving failed." >&2
    exit 1 ;;
  *"pub publish --force"*)
    touch "$STATE/flutter-published"
    log "flutter publish --force"
    exit 0 ;;
  *)
    log "flutter $*"
    exit 0 ;;
esac
EOF
  # gh: only `require gh` runs on the --local path under test.
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/curl" "$bin/dart" "$bin/flutter" "$bin/gh"
}

# ------------------------------------------------------------------ sandbox

# A throwaway git repo on master, pushed to a bare origin, holding exactly the
# files release.sh's preflight and validation read.
make_sandbox() {
  local sandbox
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/graphql-plus-release-test.XXXXXX")"
  CURRENT_SANDBOX="$sandbox"
  mkdir -p "$sandbox/repo/scripts" \
    "$sandbox/repo/packages/graphql_plus" \
    "$sandbox/repo/packages/graphql_flutter_plus" \
    "$sandbox/bin" "$sandbox/state"
  cp "$RELEASE" "$sandbox/repo/scripts/release.sh"
  cp "$ROOT/packages/graphql_plus/pubspec.yaml" \
    "$ROOT/packages/graphql_plus/CHANGELOG.md" "$sandbox/repo/packages/graphql_plus/"
  cp "$ROOT/packages/graphql_flutter_plus/pubspec.yaml" \
    "$ROOT/packages/graphql_flutter_plus/CHANGELOG.md" \
    "$sandbox/repo/packages/graphql_flutter_plus/"
  write_shims "$sandbox/bin"
  git -C "$sandbox/repo" init >/dev/null 2>&1
  git -C "$sandbox/repo" symbolic-ref HEAD refs/heads/master
  git -C "$sandbox/repo" add -A
  git -C "$sandbox/repo" -c user.email=test@example.com -c user.name=test \
    commit -qm "sandbox"
  git init -q --bare "$sandbox/origin.git"
  git -C "$sandbox/repo" remote add origin "$sandbox/origin.git"
  git -C "$sandbox/repo" push -q origin master
  echo "$sandbox"
}

run_release_local() {
  local sandbox="$1"
  (
    export PATH="$sandbox/bin:$PATH"
    export RELEASE_TEST_STATE="$sandbox/state"
    export CLIENT_VERSION FLUTTER_VERSION
    export PUBLISH_WAIT_SECONDS=30
    "$sandbox/repo/scripts/release.sh" production --local --yes
  )
}

show_run() {
  echo "--- release.sh output ---"
  cat "$1/state/output.log"
  echo "-------------------------"
}

# ------------------------------------------------------------------ tests

# 1. After the client publishes, the API `latest` field flips immediately but
#    the version is NOT yet resolvable — the script must keep probing until
#    pub get succeeds, and only then run the flutter dry run and publish.
test_wait_polls_resolvability() {
  local sandbox; sandbox="$(make_sandbox)"
  if ! run_release_local "$sandbox" >"$sandbox/state/output.log" 2>&1; then
    show_run "$sandbox"
    fail "release.sh exited nonzero: the post-client step raced the not-yet-resolvable client"
  fi
  show_run "$sandbox"
  grep -q "resolvability probe OK" "$sandbox/state/dart.log" ||
    fail "release.sh never probed resolvability — it still trusts the API latest field"
  grep -q "flutter registry dry-run OK" "$sandbox/state/flutter.log" ||
    fail "the registry-resolved flutter dry run did not run"
  grep -q "flutter publish --force" "$sandbox/state/flutter.log" ||
    fail "graphql_flutter_plus was not published"
  cleanup
  pass "post-client wait polls resolvability; flutter package published"
}

# 2. A `--local` run that died after the client shipped must be resumable: the
#    already-published client is skipped, and the flutter package is published.
test_local_resume_publishes_flutter() {
  local sandbox; sandbox="$(make_sandbox)"
  touch "$sandbox/state/client-published" # the client is already on pub.dev
  if ! run_release_local "$sandbox" >"$sandbox/state/output.log" 2>&1; then
    show_run "$sandbox"
    fail "release.sh died on the already-published client instead of resuming"
  fi
  show_run "$sandbox"
  grep -q "already on pub.dev" "$sandbox/state/output.log" ||
    fail "release.sh did not note the client was already published"
  if grep -q "client publish --force" "$sandbox/state/dart.log"; then
    fail "the client was re-published during a resume run"
  fi
  grep -q "resolvability probe OK" "$sandbox/state/dart.log" ||
    fail "the resume run skipped the resolvability wait"
  grep -q "flutter publish --force" "$sandbox/state/flutter.log" ||
    fail "the resume run never published graphql_flutter_plus"
  cleanup
  pass "--local resumes past an already-published client to the flutter publish"
}

main() {
  [ -x "$RELEASE" ] || fail "missing $RELEASE"
  test_wait_polls_resolvability
  test_local_resume_publishes_flutter
  echo "release_test: all tests passed"
}

main "$@"
