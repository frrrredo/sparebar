# Provider notes

Sparebar asks the installed official CLIs for account and usage data. It does not send prompts or start model turns.

| Tool | Read path | Caveat |
| --- | --- | --- |
| Codex | `app-server`: `account/read`, `account/rateLimits/read` | Returned buckets and windows vary by plan/version. |
| Claude Code | `auth status`, then structured `get_usage` with `skip_behaviors` | Experimental control; readings may be cached. |

Refresh runs every five minutes, with backoff on errors and another check after wake or reset. Each tool has one active read at a time. Helpers have time/output bounds, run outside coding projects, and stop on cancellation or quit. Existing managed restrictions remain in effect.

"Checked" is when the CLI responded. Missing percentages are unavailable, not zero. A passed reset waits for new data; it never invents a full allowance. Old readings stop being current after 15 minutes or a failed check. Account changes discard previous readings.

## Service status

Sparebar also reads the public [OpenAI status feed](https://status.openai.com/api/v2/summary.json) and [Claude status feed](https://status.claude.com/api/v2/summary.json) for enabled providers. These reports cover broader provider services, not just coding tools. They are independent of CLI allowance reads and require no sign-in, cookies, model calls, or Sparebar-hosted service.

Each provider is checked about every five minutes while awake, with small random offsets to spread requests. Launch and wake trigger a check after a short random delay. Requests have time and response-size limits; failures back off, and server retry instructions are respected within a one-year bound. Every scheduled check contacts the provider. When supported, an unchanged-response validator avoids downloading the same report again; it does not add an extra cache waiting period.

The eyes show reported service health, and the full face identifies the provider. Percentage and optional bar/gauge still show allowance. Official reports can lag a real incident and do not guarantee availability for every account. A failed request, unrecognized status, or report more than ten minutes old is shown as unconfirmed, not as an outage. The last report stays in memory only.

A new or worsening incident triggers one gentle pulse. An unacknowledged outage can pulse again every ten minutes; opening the popup or fallback allowance window acknowledges it. A confirmed recovery briefly shows happy eyes, then normal eyes. Reduce Motion suppresses these animations. This feature does not send system notifications.

## Troubleshooting

Use the official CLI to sign in. In Sparebar's connection settings, choose a custom executable/configuration directory if needed. A selected allowance may disappear when your plan or CLI response changes; choose another returned allowance.

`swift run sparebar-check` prints normalized personal usage locally. Do not paste its output into public issues without removing personal data. Tests use synthetic fixtures and need no provider login.

Physical sleep/wake, actual login launch, real network/sign-out failures, complete VoiceOver use, and sustained battery impact still need broader testing. Login-item state and failure handling have synthetic tests. Older macOS and Intel are not supported yet.
