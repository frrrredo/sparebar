# Provider notes

Sparebar asks the installed official CLIs for account and usage data. It does not send prompts or start model turns.

| Tool | Read path | Caveat |
| --- | --- | --- |
| Codex | `app-server`: `account/read`, `account/rateLimits/read` | Returned buckets and windows vary by plan/version. |
| Claude Code | `auth status`, then structured `get_usage` with `skip_behaviors` | Experimental control; readings may be cached. |

Refresh runs every five minutes, with backoff on errors and another check after wake or reset. Each tool has one active read at a time. Helpers have time/output bounds, run outside coding projects, and stop on cancellation or quit. Existing managed restrictions remain in effect.

While awake, the existing 30-second clock tick also recovers overdue allowance checks if their timer was delayed or lost. It respects error backoff and active reads; percentages return only after a successful fresh reading.

"Checked" is when the CLI responded. Missing percentages are unavailable, not zero. A passed reset waits for new data; it never invents a full allowance. Old readings stop being current after 15 minutes or a failed check. Account changes discard previous readings.

## Service status

Sparebar also reads the public [OpenAI status report](https://status.openai.com/proxy/status.openai.com) and [Claude status feed](https://status.claude.com/api/v2/summary.json) for enabled providers with selected services. These reports are independent of CLI allowance reads and require no sign-in, cookies, model calls, or Sparebar-hosted service.

In **Settings > Service health**, each provider has its own service choices. ChatGPT and Codex start enabled for OpenAI; claude.ai and Claude Code start enabled for Claude. APIs, FedRAMP, Ads Platform, Claude Console, Claude API, Claude Cowork, and Claude for Government start off. Preferences persist independently, including an empty selection that stops that provider's service polling. Enabling or disabling a CLI connection remains separate.

OpenAI's status page publishes current product groups and component membership in its native public report. The compatibility summary can omit services, so Sparebar uses the complete page report. This is a public website endpoint, not a documented model API contract; an incompatible schema or missing selected group produces unconfirmed status. Claude services map to their official component IDs. Incident scope comes from component IDs, never keywords in an incident title. A report without enough scope or coverage is unconfirmed rather than attributed to a guessed service.

Only selected components and their incidents drive eyes, reminders, tooltips, and panel details. An excluded outage cannot raise the severity of a selected degraded component in the same incident. Changing choices reuses the latest in-memory report without another request or a recovery animation; its original check time and failure state remain intact. Selecting a service after all choices were cleared restarts polling.

Each provider is checked about every five minutes while awake, with small random offsets to spread requests. Launch and wake trigger a check after a short random delay. Requests have time and response-size limits; failures back off, and server retry instructions are respected within a one-year bound. Every scheduled check contacts the provider. When supported, an unchanged-response validator avoids downloading the same report again; it does not add an extra cache waiting period.

The eyes show reported service health, and the full face identifies the provider. Percentage and optional bar/gauge still show allowance. Official reports can lag a real incident and do not guarantee availability for every account. A failed request, unrecognized status, or report more than ten minutes old is shown as unconfirmed, not as an outage. The last report stays in memory only.

A new or worsening incident triggers one gentle pulse. An unacknowledged outage can pulse again every ten minutes; opening the popup or fallback allowance window acknowledges it. A confirmed recovery briefly shows happy eyes, then normal eyes. Reduce Motion suppresses these animations. This feature does not send system notifications.

## Troubleshooting

Use the official CLI to sign in. In Sparebar's connection settings, choose a custom executable/configuration directory if needed. A selected allowance may disappear when your plan or CLI response changes; choose another returned allowance.

`swift run sparebar-check` prints normalized personal usage locally. Do not paste its output into public issues without removing personal data. Tests use synthetic fixtures and need no provider login.

Physical sleep/wake, actual login launch, real network/sign-out failures, complete VoiceOver use, and sustained battery impact still need broader testing. Login-item state and failure handling have synthetic tests. Older macOS and Intel are not supported yet.
