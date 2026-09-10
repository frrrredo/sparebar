# Changelog

## Unreleased

- Recover stalled automatic allowance checks so percentages do not stay unavailable until a manual refresh.

## 0.1.5

- Choose monitored services independently for OpenAI and Claude in Settings. ChatGPT, Codex, claude.ai, and Claude Code start enabled; all other services start off.
- Limit incident eyes, reminders, tooltip details, and the status panel to selected services. Save choices across launches, including an empty selection that stops that provider's service checks.
- Apply selection changes to the last report without extra requests or a false recovery animation. Incomplete or unscoped reports remain unconfirmed.
- Read OpenAI's complete public status report and current product groups instead of its incomplete compatibility summary. Keep the existing five-minute interval and failure backoff.

## 0.1.4

- Report OpenAI and Claude service incidents in the existing popup, with affected services, official status links, and separate allowance readings. Status checks run directly from the Mac about every five minutes while awake.
- Use a full provider-colored robot face with centered eyes: squares for normal service, thin lines for degradation, crosses for an outage, and muted lines for unconfirmed status.
- Add gentle incident alerts and ten-minute outage reminders until acknowledged. A brief happy-eye blink marks recovery before normal eyes return. Reduce Motion keeps the eyes still.
- Explain service health in Settings with an eye-shape legend, polling timing, and recovery behavior. Add native sample screenshots and a plain-language guide.

## 0.1.3

- Automatic updates download in the background and install when Sparebar quits, with no forced restart. One Settings switch controls this; daily checks continue when it is off.
- An orange dot, short release summary, and Update and Restart action appear in the existing panel. Full notes open behind an information button, with Back to return.
- Bundle Sparkle for verified update installation. Release preparation signs the finished DMG for Sparkle; publishing updates the public feed automatically.

## 0.1.2

- Added Show Percentage to More options and Settings, enabled by default. Hiding it reclaims the number's menu bar space and remembers the choice after restarting.
- Opening Sparebar from Applications or Spotlight shows allowances in a window, even when the menu bar item is hidden.
- Percentage on the left and a rectangular robot on the right, using the native battery outline with matching terminals on the left and at the top center. Its outline follows the system text color; only the interior fills blue for Codex or warm orange for Claude. Two 3.825-point square eyes with a 4.4-point gap stay white for Codex and black for Claude at every fill level and in both appearances. The fill matches the displayed number and drains from right to left. Percentage is the default; existing style preferences are preserved.
- Removed the reserved warning slot and custom outer padding. Warnings tint the reading while the tool's color stays fixed. Full names and overall warnings remain in the panel and tooltip. Differentiate Without Color uses distinct text labels.
- Only the robot slides upward during tool rotation. The percentage updates in place with no slide or fade.
- The robot keeps the reference battery width, with a slightly taller 23-by-14.95-point body and matching terminals. Its 11-point percentage matches the reference text size and sits three points to its left. Percentage takes 57 points for two-digit readings or 64 for `100%`, before native button spacing, and stays the same width during tool rotation.
- Refreshed the README animation and screenshots to show the current interface and percentage setting.

## 0.1.1

First signed and Apple-notarized DMG, with checksums and source provenance. Built in CI; signing stays in the maintainer's local Keychain.

## 0.1.0

First public preview. Codex and Claude Code allowances in one rotating menu-bar slot, with low-allowance warnings, meter selection, light/dark appearance, and optional launch at login.

Source build only. Apple silicon and macOS 26.5.1+. Claude usage reads are experimental; notarized downloads are planned.
