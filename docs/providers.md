# Provider notes

Sparebar asks the installed official CLIs for account and usage data. It does not send prompts or start model turns.

| Tool | Read path | Caveat |
| --- | --- | --- |
| Codex | `app-server`: `account/read`, `account/rateLimits/read` | Returned buckets and windows vary by plan/version. |
| Claude Code | `auth status`, then structured `get_usage` with `skip_behaviors` | Experimental control; readings may be cached. |

Refresh runs every five minutes, with backoff on errors and another check after wake or reset. Each tool has one active read at a time. Helpers have time/output bounds, run outside coding projects, and stop on cancellation or quit. Existing managed restrictions remain in effect.

"Checked" is when the CLI responded. Missing percentages are unavailable, not zero. A passed reset waits for new data; it never invents a full allowance. Old readings stop being current after 15 minutes or a failed check. Account changes discard previous readings.

## Troubleshooting

Use the official CLI to sign in. In Sparebar's connection settings, choose a custom executable/configuration directory if needed. A selected allowance may disappear when your plan or CLI response changes; choose another returned allowance.

`swift run sparebar-check` prints normalized personal usage locally. Do not paste its output into public issues without removing personal data. Tests use synthetic fixtures and need no provider login.

Physical sleep/wake, actual login launch, real network/sign-out failures, complete VoiceOver use, and sustained battery impact still need broader testing. Login-item state and failure handling have synthetic tests. Older macOS and Intel are not supported yet.
