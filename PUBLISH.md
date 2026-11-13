# Publishing graphql_plus

Two packages ship from this repo, in this order:

| Package | Path | Publishes with |
| --- | --- | --- |
| `graphql_plus` | `packages/graphql_plus` | `dart pub publish` |
| `graphql_flutter_plus` | `packages/graphql_flutter_plus` | `flutter pub publish` |

`graphql_flutter_plus` depends on `graphql_plus`, and pub.dev refuses a
constraint naming a version it has never served — so the client always goes
first and the flutter package follows once the client is live.

## The one command

```bash
./scripts/release.sh production        # cut the release and publish both
./scripts/release.sh production --local # same, but publish from this machine
./scripts/release.sh production --dry-run  # validate only; tag and publish nothing
```

The environment argument is `development | staging | production`. pub.dev is a
single registry, so the tier selects no target and is echoed to the release log;
`development` is the dry run.

The script refuses to run unless:

- the tree is clean, on `master`, and in sync with `origin/master`;
- both `pubspec.yaml` versions are set and both `CHANGELOG.md` files already
  carry a `# v<version>` section for them (the changelog is the release notes);
- both packages pass `pub publish --dry-run` — the client for real, the flutter
  package in a throwaway copy against the **local** client (pub.dev refuses a
  constraint naming a version it has never served), then again for real against
  the registry once the client is live;
- a publish credential exists (below) — for a real publish; a dry run stops
  before the credential check. The workflow path **refuses** without
  `CREDENTIAL_JSON` rather than tagging a release nothing would ship; only an
  unreadable secrets API (no repo admin) downgrades that to a warning that
  needs `--yes`.

It then tags `graphql_plus-v<client>` and `graphql_flutter_plus-v<flutter>`,
creates the matching GitHub releases (whose notes are the changelog section),
waits for `graphql_plus` to appear on pub.dev, and only then publishes
`graphql_flutter_plus`. It ends by reading both versions back from pub.dev.

The confirmation prompt needs a TTY. The pool's publish lane runs from a `/tmp`
clone with no terminal, so its real invocation is the `--yes` form:

```bash
./scripts/release.sh production --yes
```

A missing TTY is refused with a message rather than a silent exit.

## Credentials

pub.dev publishes are authenticated, and neither path is silent about a missing
credential:

- **GitHub Actions** — `release_dart.yml` and `release_flutter.yml` publish with
  the `CREDENTIAL_JSON` repository secret via
  `k-paxian/dart-package-publisher`. The guard is the shared composite action
  `.github/actions/check-publish-creds`: on `workflow_run` (a validation pass)
  a missing secret prints a warning and **skips** the publish step, and on a
  real `release` event it **fails the run loudly** rather than pretending a
  release shipped. That is why a missing secret must be checked before a
  release, not after. `scripts/release.sh` performs that same check itself
  before it creates any tag, so a missing credential can never leave a
  half-released repo behind.
  ```bash
  gh secret set CREDENTIAL_JSON --repo arrrrny/graphql_plus < credential.json
  ```
- **This machine** (`--local`) — a pub.dev token, or `PUB_CREDENTIALS_JSON` /
  `CREDENTIAL_JSON` in the environment:
  ```bash
  dart pub token add https://pub.dev   # token from pub.dev → Account → Tokens
  ```

`scripts/release.sh` checks which of these it has before it tags anything.

## What the release workflows do

Both workflows also run on `workflow_run` after Test/Build on `master`, where
they publish with `dryRunOnly: true` — a validation pass, never a publish. Only
a GitHub release (`release: created`) publishes for real.

A `release` event carries no usable tag filter — GitHub ignores `tags:` under
`on: release`, so every release reaches every workflow — so each publish job
gates on `github.event.release.tag_name` instead. That gate is the publish-order
guarantee: `Release (dart)` runs only for `graphql_plus-v*`, and
`Release (flutter)` only for `graphql_flutter_plus-v*`, which is why creating the
client release cannot race the flutter publish.

There is no third publish workflow: the upstream `release_packages.yml` leftover
published both packages on every release and has been removed.

## For the forklift publish lane

The pool's PUBLISH task runs this flow from a `/tmp` clone of `master`; this
file and `scripts/release.sh` are its contract. A publish that arrives before
the version bump is merged therefore cannot ship an old version — the script
refuses when the target version is already on pub.dev, and the changelog check
refuses a version nobody described.
