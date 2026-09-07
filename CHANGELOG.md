# Changelog

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
