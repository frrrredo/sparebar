# Sparebar

See what's left in Codex and Claude Code without opening either tool. One rotating macOS menu-bar slot keeps both allowances in view without taking over your menu bar.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/allowances-dark.jpg">
  <img src="docs/images/allowances-light.jpg" width="360" alt="Sparebar showing Codex at 64% remaining and Claude at 18%, with a low allowance warning.">
</picture>

Actual app, sample allowances. [Settings screenshot](docs/images/settings.jpg).

## Try it

Early preview. Build from source for now; a notarized download will follow.

Requires Apple silicon, macOS 26.5.1 or newer, Xcode, and a signed-in [Codex CLI](https://learn.chatgpt.com/docs/cli) or [Claude Code](https://code.claude.com/docs/en/setup) subscription account.

```sh
git clone https://github.com/frrrredo/sparebar.git
cd sparebar
./scripts/package-app.sh
open dist/Sparebar.app
```

First launch opens your allowances directly. Missing tools get a setup link. Move the app to Applications if you want to enable **Launch at login** in Settings.

## Small by design

- Rotates between tools; opening the panel pauses it.
- Weekly, session, and model allowances when available.
- Bar, gauge, or percentage; remaining by default, used if you prefer.
- Amber at 20% left, red at 10%. Missing readings show `--`.

Your official CLIs handle sign-in. Sparebar sends no model prompts, stores no credentials or usage history, and has no analytics or third-party package dependencies. [How reads work](docs/providers.md).

Claude's usage control is experimental and can return cached readings. Tested with Codex 0.153.4 and Claude Code 2.1.263. Older macOS and Intel support can follow demand.

## Contribute

[Bugs and ideas](https://github.com/frrrredo/sparebar/issues) are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, tests, and small pull requests. Keep the app simple.

Personal project by [frrrredo](https://github.com/frrrredo). Independent of OpenAI and Anthropic. [Apache-2.0](LICENSE).
