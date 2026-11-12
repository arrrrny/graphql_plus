<!-- ZURAFFA-LAUNCH-PROMO (valid until Dec 1, 2026) -->
## 🦒 [Zuraffa Browser](https://zuraffa.com) — now live

<div align="center">
  <a href="https://zuraffa.com"><img src="https://zuraffa.com/img/zuraffa-browser-home.jpg" alt="Zuraffa Browser — 10 Browsers. One window." width="800"></a>
</div>

**[Zuraffa Browser](https://zuraffa.com)** — the multi-tasking browser for AI agents & humans — is live on the [Mac App Store](https://apps.apple.com/app/id6811352058).

🎁 **Launch offer: 6 months free with code `ZURAFFA`** — no credit card, no subscription, no payment. Redeem in-app until **Dec 1, 2026**.

---

<div align="center">
  <h1>GraphQL Plus</h1>

  <p>
    <strong>A collection of packages to work with graphql server in dart and flutter.</strong>
  </p>

  <h4>
    <a href="https://github.com/arrrrny/graphql_plus">Project Homepage</a>
  </h4>

  <a href="https://pub.dev/packages/graphql_plus">
    <img alt="graphql_plus on pub.dev" src="https://img.shields.io/pub/v/graphql_plus?style=flat-square"/>
  </a>

  <a href="https://pub.dev/packages/graphql_flutter_plus">
    <img alt="graphql_flutter_plus on pub.dev" src="https://img.shields.io/pub/v/graphql_flutter_plus?style=flat-square"/>
  </a>

</div>

## Introduction

GraphQL brings many benefits, both to the client: devices will need fewer requests, and therefore reduce data usage. And to the programmer: requests are arguable, they have the same structure as the request.

This project combines the benefits of GraphQL with the benefits of `Streams` in Dart to deliver a high-performance client.

The project took inspiration from the [Apollo GraphQL client](https://github.com/apollographql/apollo-client), great work guys!

## Packages

This is a Monorepo which contains the following packages:

| Package     | Description |  Version |
|:----------|:-----------:|--:|
| [graphql_plus](./packages/graphql_plus) | Client implementation to interact with any graphql server  | ![Pub Version (including pre-releases)](https://img.shields.io/pub/v/graphql_plus?include_prereleases&style=flat-square)  |
| [graphql_flutter_plus](./packages/graphql_flutter_plus) | Flutter Widgets wrapper around graphql API | ![Pub Version (including pre-releases)](https://img.shields.io/pub/v/graphql_flutter_plus?include_prereleases&style=flat-square) |

## Utils Tools

Around `graphql_flutter` are builds awesome tools like:

1. [graphql_flutter_bloc](https://github.com/artflutter/graphql_flutter_bloc)
2. [graphql_codegen](https://github.com/heftapp/graphql_codegen)
3. [graphql-cache-inspector](https://pub.dev/packages/graphql_cache_inspector)

## Features

✅ &nbsp; Queries, Mutations, and Subscriptions  
✅ &nbsp; [Query polling and rebroadcasting](./packages/graphql_plus/README.md#clientwatchquery-and-observablequery)  
✅ &nbsp; [In memory and persistent caching](./packages/graphql_plus/README.md#persistence)  
✅ &nbsp; [GraphQL Upload](./packages/graphql_plus/README.md#graphql-upload)  
✅ &nbsp; [Optimistic results](./packages/graphql_flutter_plus/README.md#optimism)  
✅ &nbsp; [Modularity](./packages/graphql_plus/README.md#links)  
✅ &nbsp; [Client-state management](./packages/graphql_plus/README.md#direct-cache-access-api)  
✅ &nbsp; [Operation cancellation](./packages/graphql_plus/README.md#cancellation)  
⚠️  &nbsp; [Automatic Persisted Queries](./packages/graphql_plus/README.md#persistedquerieslink-experimental-warning-out-of-service-warning) (out of service)  

## Contributing

Please see our [Hacking guide](./docs/dev/MAINTAINERS.md)

## Contributors

This package was originally created and published by the engineers at [Zino App BV](https://zinoapp.com). Since then the community has helped to make it even more useful for even more developers.

This project follows the [all-contributors](https://github.com/kentcdodds/all-contributors) specification. Contributions of any kind are welcome!

[build-status-badge]: https://img.shields.io/github/actions/workflow/status/arrrrny/graphql_plus/build.yml?branch=master&style=flat-square
[build-status-link]: https://github.com/arrrrny/graphql_plus/actions
[coverage-badge]: https://img.shields.io/codecov/c/github/arrrrny/graphql_plus?style=flat-square
[coverage-link]: https://app.codecov.io/gh/arrrrny/graphql_plus
[version-badge]: https://img.shields.io/pub/v/graphql_flutter_plus.svg?style=flat-square
[package-link]: https://pub.dev/packages/graphql_flutter_plus
[package-link-client]: https://pub.dev/packages/graphql_plus
[license-badge]: https://img.shields.io/github/license/arrrrny/graphql_plus.svg?style=flat-square
[license-link]: https://github.com/arrrrny/graphql_plus/blob/master/LICENSE
[prs-badge]: https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square
[prs-link]: http://makeapullrequest.com

## Articles and Videos

External guides, tutorials, and other resources from the GraphQL Flutter community

- [Ultimate toolchain to work with GraphQL in Flutter](https://medium.com/@v.ditsyak/ultimate-toolchain-to-work-with-graphql-in-flutter-13aef79c6484):  
  An intro to using `graphql_flutter` with [`artemis`](https://pub.dev/packages/artemis) for code generation and [`graphql-faker`](https://github.com/APIs-guru/graphql-faker) for API prototyping

---

> **Fork packages**: the Dart client is [`graphql_plus`](https://pub.dev/packages/graphql_plus)
> (`packages/graphql_plus`, fork of `graphql` 5.2.4) and the Flutter widgets layer is
> [`graphql_flutter_plus`](https://pub.dev/packages/graphql_flutter_plus)
> (`packages/graphql_flutter_plus`, fork of `graphql_flutter` 5.3.0, rebuilt on `graphql_plus`).
> See [UPSTREAM_ISSUES_TRIAGE.md](UPSTREAM_ISSUES_TRIAGE.md) for how we triage and revive the
> upstream issue backlog.
