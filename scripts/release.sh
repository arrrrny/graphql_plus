#!/usr/bin/env bash
# Cut a release of the two published packages and put them on pub.dev.
#
#   ./scripts/release.sh <environment> [options]
#
# <environment> is development | staging | production. pub.dev is ONE registry,
# so the tier selects NO target — it is echoed to the release log and nowhere
# else: a graphql_plus release always publishes both packages to pub.dev. The
# argument exists so the fleet's publish contract (`PUBLISH.md`) is the same
# shape here as on every other repo, and so `development` means "build and
# validate locally, ship nothing" — the dry run.
#
# options
#   --dry-run       validate only: no tag, no release, no publish. Same as
#                   <environment> = development.
#   --local         publish from this machine instead of through the GitHub
#                   release workflows. Needs a pub.dev credential (below).
#   --yes           do not ask for confirmation before the irreversible step.
#
# The publish order matters: graphql_flutter_plus depends on graphql_plus, and
# pub.dev refuses a constraint that names a version it has never seen — so the
# client goes first and the flutter package only after the client is live.
#
# Credentials. The GitHub workflows (release_dart.yml / release_flutter.yml)
# publish through `k-paxian/dart-package-publisher` with the `CREDENTIAL_JSON`
# secret, checked by the shared `.github/actions/check-publish-creds` action,
# which skips loudly on a validation pass and FAILS the run on a real release
# event. A real publish therefore requires one of the following — a dry run
# stops before the credential check, and the workflow path warns and then
# requires `--yes`:
#
#   * CREDENTIAL_JSON in the environment (the pub site's JSON credential), or
#   * PUB_CREDENTIALS_JSON (same payload, the name `dart pub publish` reads), or
#   * a pub.dev token already on this machine — `dart pub token list` must name
#     https://pub.dev (that is what --local uses).
#
# Everything else — tags, releases, verification — needs only `gh`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLIENT_DIR="packages/graphql_plus"
FLUTTER_DIR="packages/graphql_flutter_plus"
CLIENT_NAME="graphql_plus"
FLUTTER_NAME="graphql_flutter_plus"
PUBLISH_WAIT_SECONDS="${PUBLISH_WAIT_SECONDS:-600}"

ENVIRONMENT=""
DRY_RUN=0
LOCAL=0
ASSUME_YES=0

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

for arg in "$@"; do
  case "$arg" in
    development | staging | production) ENVIRONMENT="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    --local) LOCAL=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" |
        sed -e '${/^[^#]/d;}' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

[ -n "$ENVIRONMENT" ] || die "an environment is required: development | staging | production"
[ "$ENVIRONMENT" = "development" ] && DRY_RUN=1

require() { command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH"; }
require git
require gh
require curl

version_of() {
  local pubspec="$1"
  awk '/^version:[[:space:]]*/ { print $2; exit }' "$pubspec"
}

changelog_notes() {
  local changelog="$1" version="$2"
  awk -v heading="# v$version" '
    index($0, heading) == 1 { found = 1; next }
    found && /^# / { exit }
    found { print }
  ' "$changelog"
}

# ---------------------------------------------------------------- preflight

step "Preflight"

git fetch origin --tags --quiet
LOCAL_HEAD="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE_HEAD="$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "")"
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
  die "the working tree has modified tracked files — a release must be cut from a clean tree"

# A real publish ships what is on master, so it is cut there and only there. A
# dry run is validation: it must also be runnable on the release branch, before
# the merge, which is exactly when you want to know the packages are publishable.
if [ "$DRY_RUN" = 0 ]; then
  [ "$BRANCH" = "master" ] ||
    die "releases are cut from master (this tree is on $BRANCH)"
  [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] ||
    die "master is not in sync with origin/master — pull --ff-only first"
elif [ -n "$REMOTE_HEAD" ] && [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
  echo "note: $BRANCH is not in sync with origin/$BRANCH — validating the local tree"
fi

CLIENT_VERSION="$(version_of "$CLIENT_DIR/pubspec.yaml")"
FLUTTER_VERSION="$(version_of "$FLUTTER_DIR/pubspec.yaml")"
[ -n "$CLIENT_VERSION" ] || die "no version in $CLIENT_DIR/pubspec.yaml"
[ -n "$FLUTTER_VERSION" ] || die "no version in $FLUTTER_DIR/pubspec.yaml"

CLIENT_TAG="$CLIENT_NAME-v$CLIENT_VERSION"
FLUTTER_TAG="$FLUTTER_NAME-v$FLUTTER_VERSION"

# The changelog is the release notes, so its heading must already describe the
# version being cut — a version bumped without its entry is the failure this
# catches before anything leaves the machine.
grep -q "^# v$CLIENT_VERSION" "$CLIENT_DIR/CHANGELOG.md" ||
  die "$CLIENT_DIR/CHANGELOG.md has no '# v$CLIENT_VERSION' section"
grep -q "^# v$FLUTTER_VERSION" "$FLUTTER_DIR/CHANGELOG.md" ||
  die "$FLUTTER_DIR/CHANGELOG.md has no '# v$FLUTTER_VERSION' section"

echo "environment     : $ENVIRONMENT"
echo "client          : $CLIENT_NAME $CLIENT_VERSION ($CLIENT_TAG)"
echo "flutter         : $FLUTTER_NAME $FLUTTER_VERSION ($FLUTTER_TAG)"
echo "mode            : $([ "$DRY_RUN" = 1 ] && echo 'dry run (nothing is published)' || echo "publish via $([ "$LOCAL" = 1 ] && echo 'this machine' || echo 'the GitHub release workflows')")"

# pub.dev is immutable: a version that already exists cannot be re-cut, and the
# whole point of a re-run is to finish one that died half way.
if [ "$DRY_RUN" = 0 ]; then
  published_client="$(curl -s --max-time 20 "https://pub.dev/api/packages/$CLIENT_NAME" |
    sed -n 's/.*"latest":[[:space:]]*{[^}]*"version":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$published_client" ] ||
    echo "note: $CLIENT_NAME is not on pub.dev yet (first publish)"
  if [ "$published_client" = "$CLIENT_VERSION" ]; then
    die "$CLIENT_NAME $CLIENT_VERSION is already on pub.dev — nothing to publish"
  fi
  published_flutter="$(curl -s --max-time 20 "https://pub.dev/api/packages/$FLUTTER_NAME" |
    sed -n 's/.*"latest":[[:space:]]*{[^}]*"version":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$published_flutter" ] ||
    echo "note: $FLUTTER_NAME is not on pub.dev yet (first publish)"
  if [ "$published_flutter" = "$FLUTTER_VERSION" ]; then
    die "$FLUTTER_NAME $FLUTTER_VERSION is already on pub.dev — nothing to publish"
  fi
fi

# ------------------------------------------------------------- validation

step "Validate both packages (pub publish --dry-run)"

require dart
require flutter

# The client has no local dependency, so it validates exactly as it will publish.
(cd "$CLIENT_DIR" && dart pub publish --dry-run)

# graphql_flutter_plus declares `graphql_plus: ^<client version>`, and pub.dev
# refuses a constraint naming a version it has never served — so before the
# client is live the honest validation of the flutter package is against the
# LOCAL client, in a throwaway copy that carries a path override. Never in the
# tree itself: a published pubspec must not carry an override, and the real,
# registry-resolved validation happens after the client is live (below).
validate_flutter_locally() {
  local scratch client_abs
  client_abs="$(cd "$CLIENT_DIR" && pwd)"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/graphql-plus-flutter-validate.XXXXXX")"
  cp -R "$FLUTTER_DIR/." "$scratch/" || return 1
  cat >>"$scratch/pubspec.yaml" <<EOF

dependency_overrides:
  $CLIENT_NAME:
    path: $client_abs
EOF
  if (cd "$scratch" && flutter pub publish --dry-run --ignore-warnings); then
    rm -rf "$scratch"
    return 0
  fi
  rm -rf "$scratch"
  return 1
}

if validate_flutter_locally; then
  echo "$FLUTTER_NAME validates against the local $CLIENT_NAME (registry-resolved validation follows once the client is live)"
else
  die "$FLUTTER_NAME does not validate against the local $CLIENT_NAME — fix that before releasing"
fi

[ "$DRY_RUN" = 1 ] && {
  step "Dry run complete"
  echo "Both packages validate. Re-run without --dry-run (and with a pub.dev credential) to ship."
  exit 0
}

# ------------------------------------------------------------- credentials

step "Check publish credentials"

has_pub_dev_token() {
  dart pub token list 2>/dev/null | grep -q '^https://pub\.dev$'
}

# The workflows publish with the CREDENTIAL_JSON repository secret. Any OTHER
# secret in the list does not authenticate a publish, so a check that only asks
# "does the repo have secrets at all?" answers yes for a repo that cannot
# publish — which is the inversion this guard was written to prevent.
#
# Prints: yes | no | unknown (unknown = the secrets API was unreadable, e.g. the
# caller lacks admin on the repo — that is not the same as "absent").
repo_publish_secret_state() {
  local count
  if ! count="$(gh api "repos/arrrrny/graphql_plus/actions/secrets" \
    --jq '[.secrets[] | select(.name == "CREDENTIAL_JSON")] | length' 2>/dev/null)"; then
    echo unknown
    return 0
  fi
  case "${count:-}" in
    '' | *[!0-9]*) echo unknown ;;
    0) echo no ;;
    *) echo yes ;;
  esac
}

if [ "$LOCAL" = 1 ]; then
  if [ -z "${PUB_CREDENTIALS_JSON:-${CREDENTIAL_JSON:-}}" ] && ! has_pub_dev_token; then
    die "no pub.dev credential on this machine.
  Add one, then re-run with --local:
    dart pub token add https://pub.dev          # paste a token from
                                                # pub.dev → Account → Tokens
  (or export PUB_CREDENTIALS_JSON with the pub site's JSON credential)"
  fi
else
  # A missing credential is fatal BEFORE anything is tagged: a run that tags and
  # releases first leaves a half-state behind (tags and releases with nothing
  # published), which a re-run then has to reason about. `--yes` does not
  # override it — it only skips the interactive prompt.
  secret_state="$(repo_publish_secret_state)"
  case "$secret_state" in
    yes) ;;
    no)
      die "the repository has no CREDENTIAL_JSON secret, so the release workflows
  cannot publish — refusing to tag a release nothing would ship.
  Add the credential:  gh secret set CREDENTIAL_JSON --repo arrrrny/graphql_plus < credential.json
  or publish from this machine:  ./scripts/release.sh $ENVIRONMENT --local"
      ;;
    *)
      echo "WARNING: could not read the repository's secrets (gh needs admin on"
      echo "         arrrrny/graphql_plus), so the CREDENTIAL_JSON check is unknown."
      echo "         The release workflows will FAIL the release run if it is absent."
      [ "$ASSUME_YES" = 1 ] || die "re-run with --yes to tag and release with an unverified credential, or add it first"
      ;;
  esac
fi

# ------------------------------------------------------------ tag and release

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] ||
    die "refusing to publish: no TTY for the confirmation prompt — re-run with --yes"
  printf '\nAbout to publish %s %s and %s %s to pub.dev. Continue? [y/N] ' \
    "$CLIENT_NAME" "$CLIENT_VERSION" "$FLUTTER_NAME" "$FLUTTER_VERSION"
  read -r reply || die "no answer on stdin — re-run with --yes to publish unattended"
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) die "aborted at the operator's request" ;;
  esac
}

if [ "$LOCAL" = 0 ]; then
  confirm
  step "Tag and create the GitHub releases"

  notes="$(mktemp -t graphql-plus-notes)"
  changelog_notes "$CLIENT_DIR/CHANGELOG.md" "$CLIENT_VERSION" >"$notes"
  if git rev-parse -q --verify "refs/tags/$CLIENT_TAG" >/dev/null; then
    echo "tag $CLIENT_TAG already exists — reusing it"
  else
    git tag -a "$CLIENT_TAG" -m "$CLIENT_NAME $CLIENT_VERSION"
    git push origin "refs/tags/$CLIENT_TAG"
  fi
  if gh release view "$CLIENT_TAG" --repo arrrrny/graphql_plus >/dev/null 2>&1; then
    echo "release $CLIENT_TAG already exists — skipping creation"
  else
    gh release create "$CLIENT_TAG" --repo arrrrny/graphql_plus \
      --title "$CLIENT_NAME v$CLIENT_VERSION" --notes-file "$notes" --verify-tag
  fi
  rm -f "$notes"
  echo "released $CLIENT_TAG — Release (dart) is publishing $CLIENT_NAME"

  # The flutter package's constraint must resolve on pub.dev before it can be
  # published, so wait for the client to be live rather than racing the workflow.
  step "Wait for $CLIENT_NAME $CLIENT_VERSION on pub.dev"
  deadline=$((SECONDS + PUBLISH_WAIT_SECONDS))
  until [ "$(curl -sf --max-time 20 "https://pub.dev/api/packages/$CLIENT_NAME" |
    sed -n 's/.*"latest":[[:space:]]*{[^}]*"version":[[:space:]]*"\([^"]*\)".*/\1/p')" = "$CLIENT_VERSION" ]; do
    [ "$SECONDS" -lt "$deadline" ] ||
      die "$CLIENT_NAME $CLIENT_VERSION did not appear on pub.dev within ${PUBLISH_WAIT_SECONDS}s — check the Release (dart) run: gh run list --workflow 'Release (dart)'"
    sleep 15
  done
  echo "$CLIENT_NAME $CLIENT_VERSION is live"

  # Now that the client is on pub.dev, the flutter package can be validated for
  # real — against the registry constraint it will actually publish under, not
  # the local override the preflight used.
  step "Validate $FLUTTER_NAME against the live $CLIENT_NAME"
  (cd "$FLUTTER_DIR" && flutter pub publish --dry-run)

  notes="$(mktemp -t graphql-plus-notes)"
  changelog_notes "$FLUTTER_DIR/CHANGELOG.md" "$FLUTTER_VERSION" >"$notes"
  if git rev-parse -q --verify "refs/tags/$FLUTTER_TAG" >/dev/null; then
    echo "tag $FLUTTER_TAG already exists — reusing it"
  else
    git tag -a "$FLUTTER_TAG" -m "$FLUTTER_NAME $FLUTTER_VERSION"
    git push origin "refs/tags/$FLUTTER_TAG"
  fi
  if gh release view "$FLUTTER_TAG" --repo arrrrny/graphql_plus >/dev/null 2>&1; then
    echo "release $FLUTTER_TAG already exists — skipping creation"
  else
    gh release create "$FLUTTER_TAG" --repo arrrrny/graphql_plus \
      --title "$FLUTTER_NAME v$FLUTTER_VERSION" --notes-file "$notes" --verify-tag
  fi
  rm -f "$notes"
  echo "released $FLUTTER_TAG — Release (flutter) is publishing $FLUTTER_NAME"
else
  confirm
  step "Publish from this machine"
  (cd "$CLIENT_DIR" && dart pub publish --force)
  step "Wait for $CLIENT_NAME $CLIENT_VERSION on pub.dev"
  deadline=$((SECONDS + PUBLISH_WAIT_SECONDS))
  until [ "$(curl -sf --max-time 20 "https://pub.dev/api/packages/$CLIENT_NAME" |
    sed -n 's/.*"latest":[[:space:]]*{[^}]*"version":[[:space:]]*"\([^"]*\)".*/\1/p')" = "$CLIENT_VERSION" ]; do
    [ "$SECONDS" -lt "$deadline" ] ||
      die "$CLIENT_NAME $CLIENT_VERSION did not appear on pub.dev within ${PUBLISH_WAIT_SECONDS}s"
    sleep 10
  done
  (cd "$FLUTTER_DIR" && flutter pub publish --dry-run)
  (cd "$FLUTTER_DIR" && flutter pub publish --force)
fi

# -------------------------------------------------------------- verification

step "Verify both packages on pub.dev"
for pair in "$CLIENT_NAME:$CLIENT_VERSION" "$FLUTTER_NAME:$FLUTTER_VERSION"; do
  name="${pair%%:*}"
  version="${pair##*:}"
  live="$(curl -sf --max-time 20 "https://pub.dev/api/packages/$name" |
    sed -n 's/.*"latest":[[:space:]]*{[^}]*"version":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ "$live" = "$version" ] ||
    die "$name is at ${live:-unknown} on pub.dev, expected $version"
  echo "$name $version — live on pub.dev"
done

step "Release complete"
echo "$CLIENT_TAG and $FLUTTER_TAG are published."
