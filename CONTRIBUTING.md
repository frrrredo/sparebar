# Contributing

Small fixes, clearer errors, and compatibility reports are welcome. Open an issue before adding a provider or changing the UI so we can agree on scope.

1. Fork the repo and create a branch from `main`.
2. Make one focused change.
3. Run `swift test` and `./scripts/package-app.sh` on an Apple silicon Mac.
4. Open a pull request with the problem, change, and checks you ran. Include before/after screenshots for UI changes; use sample data.

CI builds and tests every pull request. The maintainer reviews and squash-merges into `main`; releases are separate.

## Keep it small

- Use Swift and Apple frameworks. Discuss new dependencies first.
- Keep setup in the normal interface. Avoid tours, forced choices, and permission prompts on launch.
- Add a regression test for behavior changes. Pure copy or visual fixes need a UI check, not a test that repeats the implementation.
- Use synthetic provider responses. Never commit tokens, account identifiers, personal usage, or raw CLI output.
- You are responsible for understanding and checking submitted code, regardless of how it was written.

`UsageCore` models readings; `UsageProviders` owns CLI transport; `UsageApp` owns native UI; `UsageCheck` is a local diagnostic. [Provider notes](docs/providers.md) explain the integration limits.

Participation follows the [code of conduct](CODE_OF_CONDUCT.md). Contributions use [Apache-2.0](LICENSE).
