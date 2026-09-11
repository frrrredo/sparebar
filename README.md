# Sparebar

See what's left in Codex and Claude Code, and whether their providers report service problems. One rotating macOS menu-bar slot keeps allowances and service health in view.

<img src="docs/images/service-health-dark.png" width="332" alt="Sparebar reporting a sample Claude Code outage above separate Codex and Claude allowance readings.">

Native view with synthetic service reports and sample allowances.

## Try it

**[Download Sparebar for Apple silicon](https://github.com/frrrredo/sparebar/releases)** - signed and notarized, early preview.

Choose the DMG from the newest release, open it, drag Sparebar into Applications, then open Sparebar.

Requires Apple silicon, macOS 26.5.1 or newer, and a signed-in [Codex CLI](https://learn.chatgpt.com/docs/cli) or [Claude Code](https://code.claude.com/docs/en/setup) subscription account.

First launch opens your allowances directly. Missing tools get a setup link. **Launch at login** is optional in Settings.

<details>
<summary>Build from source</summary>

Requires Xcode.

```sh
git clone https://github.com/frrrredo/sparebar.git
cd sparebar
./scripts/package-app.sh
open dist/Sparebar.app
```

</details>

## Small by design

- Rotates between tools; opening the panel pauses it.
- Weekly, session, and model allowances when available.
- Percentage beside a compact battery-shaped robot. Blue identifies Codex; orange identifies Claude. During normal service, its fill follows the displayed allowance and drains from right to left. The eyes remain readable in the empty area. Only the robot slides during rotation; digits update in place. Hover for the tool name and reported service status.
- Remaining by default, used if you prefer. Readings turn amber at 20% left and red at 10%; the tool's color stays fixed. Missing readings show `--`.
- **Show Percentage** is on by default. Turn it off in the panel's **More options** menu or Settings to hide the number; the preference is saved.
- Checks for updates once a day. **Automatic updates** is on by default: new versions download in the background and install when you quit. Sparebar never restarts itself unexpectedly.
- An orange dot marks an available update. Open the panel for a short "What's new" message, full notes behind the info button, and **Update and Restart** (or **Restart to Update** when ready). Turn automatic updates off to choose each download; daily checks continue.

If a crowded menu bar hides Sparebar (for example, during a video call), open it from Applications or Spotlight to see your allowances in a window. For the narrowest display, turn off **Show Percentage** and set **Extra meter** to **None** in Settings. When visible, hold Command and drag Sparebar nearer the clock to give it priority over items to its left. macOS can still hide items when space runs out.

Your official CLIs handle sign-in. Sparebar sends no model prompts, stores no provider credentials or allowance history, and has no analytics. It keeps account-scoped reset receipts and pending request IDs locally so a retry cannot spend another spare. [Sparkle](https://sparkle-project.org/) is bundled for updates; checks contact GitHub without sending provider readings or a system profile. [How reads work](docs/providers.md).

Versions through 0.1.2 need one manual installation of an updater-enabled release. Subsequent releases can update in place. Updates must be published before they can be discovered.

Claude's usage control is experimental and can return cached readings. Tested with Codex 0.153.4 and Claude Code 2.1.263. Older macOS and Intel support can follow demand.

## Spare batteries for Codex

Codex accounts that report usage resets show a small battery reserve beneath their allowance. Filled batteries on the left are available; empty batteries on the right are confirmed resets used in Sparebar on this Mac. The counts remain visible when more batteries exist than fit in the strip.

At 10% remaining or less, a fresh reading with available spares offers **Use a spare**. Review the account and reported reset details, then choose **Use 1 reset**. OpenAI chooses the eligible reset and limits to restore; Sparebar checks the resulting allowance and reserve. A healthy allowance has no reset prompt, and an empty reserve says **No spares available**.

An interrupted request stays available as **Review pending reset**, including after restarting Sparebar. Retrying uses the same saved request ID. Sparebar never uses a reset automatically, and it does not count expiration or use in other apps as local use.

<p>
  <img src="docs/images/reserves-low-dark.png" width="332" alt="Native Sparebar with synthetic low Codex allowance, three filled spare batteries and two used batteries, plus Use a spare.">
  <img src="docs/images/reserves-healthy-light.png" width="332" alt="Native Sparebar with synthetic healthy allowance and a quiet horizontal reserve, with no reset action.">
</p>

Native views with synthetic data. Reserve availability and redemption depend on the installed Codex CLI and account. If unsupported, update the official CLI. See [reset behavior and local storage](docs/providers.md#codex-usage-resets).

## Service health

Keep an eye on your allowance and the services behind it.

Service health is included from version 0.1.4. Sparebar reads public service reports for OpenAI and Claude about every five minutes while your Mac is awake. Its eyes show normal service, degradation, an outage, or unconfirmed status. During normal service, the battery fill represents the displayed allowance. Degraded, outage, and unconfirmed states keep a full face so their eye shapes stay clear; percentage and optional meters continue to show allowance.

Native battery states with sample data:

<p>
  <img src="docs/images/battery-fill-light.png" width="383" alt="Light appearance: Codex and Claude battery fill at full, partial, empty, and unavailable readings, followed by full-face service-health signals.">
  <img src="docs/images/battery-fill-dark.png" width="383" alt="Dark appearance: both providers keep readable eyes across filled and empty battery areas.">
</p>

Open the panel to see which service is affected and follow the official status link for details. A gentle pulse marks a new incident, with ten-minute outage reminders until you open the panel. Happy eyes briefly mark recovery. Reduce Motion keeps the eyes still. These public status checks require no extra account or API key.

From version 0.1.5, **Settings > Service health > Choose...** lets you select services independently for OpenAI and Claude. ChatGPT, Codex, claude.ai, and Claude Code start enabled; APIs, developer consoles, government services, Claude Cowork, and Ads Platform start off. Your choices are saved. Only selected services affect the eyes and panel, so an unrelated government or API incident stays out of your way.

Clear all choices for a provider to stop its service checks. Allowance readings continue independently. Changing the selection uses the last report immediately, without an extra request or a recovery celebration. Reports that do not identify the affected services clearly remain unconfirmed.

| Eyes | Meaning |
| --- | --- |
| Squares | No incidents reported for selected services. |
| Thin lines | Degraded service or maintenance reported. |
| Crosses | An outage is reported for at least one selected service. |
| Muted lines | Service status could not be confirmed. |

**Settings > Service health** keeps this explanation close at hand. Provider reports describe shared services; they do not replace your allowance reading or diagnose your Mac's connection.

[Read how service reports work](docs/providers.md#service-status).

Native preview with synthetic service reports and sample allowances:

<p>
  <img src="docs/images/service-health-light.png" width="332" alt="Light appearance: a reported Claude Code outage beside separate Codex and Claude allowances.">
  <img src="docs/images/service-health-dark.png" width="332" alt="Dark appearance: the same sample outage with affected service, official status link, and independent allowances.">
</p>

The service choices and eye-shape guide inside Settings (sample data):

<p>
  <img src="docs/images/service-filters-light.png" width="400" alt="Light native Settings with independent OpenAI and Claude service choices.">
  <img src="docs/images/service-filters-dark.png" width="400" alt="Dark native Settings with Claude's own service checklist and the eye-shape guide.">
</p>

## Contribute

[Bugs and ideas](https://github.com/frrrredo/sparebar/issues) are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, tests, and small pull requests. Keep the app simple.

Personal project by [frrrredo](https://github.com/frrrredo). Independent of OpenAI and Anthropic. [Apache-2.0](LICENSE).
