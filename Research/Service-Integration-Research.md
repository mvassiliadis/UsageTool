# Service Integration Research

**Product:** UsageTool — native macOS 27 menu-bar usage utility
**Research date:** 2026-09-19 (revision 2, independently source-verified)
**Status:** Implementation brief. Companion: `Design/UsageTool-UI-Spec.md` (revision 2).

> This document summarizes published technical interfaces and policies; it is not legal advice or vendor approval. Provider APIs, terms, and product behavior change. Re-verify the linked sources before release.

**Evidence legend** — every non-obvious claim below is tagged:
`[F]` **Fact**: quoted or directly stated in the linked official documentation.
`[I]` **Inference**: a reasonable engineering conclusion not stated verbatim by the vendor.
`[?]` **Unresolved**: must be answered by a spike before the affected code is written. All open items are collected in §6.

---

## 0. Scope, boundary, and exclusions

### 0.1 What UsageTool reports

Personal subscription capacity only, plus one prepaid balance:

| Provider | v1 data | Source | Credentials held by UsageTool |
|---|---|---|---|
| OpenAI Codex | Personal subscription rate-limit windows, % remaining + reset time + plan | Official **local Codex App Server** JSON-RPC protocol | None |
| Anthropic Claude | Personal subscription 5-hour and 7-day windows, % remaining + reset time | User-enabled **Claude Code `statusLine` adapter** writing a sanitized snapshot file | None |
| OpenRouter | Remaining USD account credits | `GET /api/v1/credits` | One management key, in Keychain |

### 0.2 Explicit exclusion: organization Admin usage/cost APIs

OpenAI's organization endpoints (`GET /v1/organization/usage/completions`, `GET /v1/organization/costs`, Admin API key) and Anthropic's Usage & Cost Admin API (`GET /v1/organizations/usage_report/messages`, `GET /v1/organizations/cost_report`, Admin credentials) report **API-platform consumption for an organization**, not a person's ChatGPT or Claude subscription allowance. `[F]` Anthropic states plainly: *"The Admin API is unavailable for individual accounts."*

**These are out of product scope.** Do not implement them, do not add Admin/organization API-key fields, and do not add settings for them. If an "API spend" feature is ever built it is a separate product surface with separate naming. This exclusion mirrors `Design/UsageTool-UI-Spec.md` §6 and §15.

Also out of scope: Anthropic Enterprise Analytics APIs, Claude apps gateway spend limits, OpenRouter key limits / per-key usage / generation logs, and OpenRouter OAuth PKCE.

### 0.3 Hard boundary

UsageTool consumes only documented provider interfaces and explicit user-enabled exports. It must never:

- call private or undocumented endpoints — specifically **never** `/backend-api/wham/usage` or any other ChatGPT/Claude web-app internal route;
- scrape authenticated provider dashboards or parse `/status`, `/usage` or other human-facing terminal rendering;
- collect browser cookies or session tokens;
- read `~/.codex/auth.json`, `~/.claude/.credentials.json`, Claude Code Keychain entries, or any other vendor's credential store;
- reuse or proxy Claude Free/Pro/Max OAuth credentials, or offer a "Sign in with Claude" control;
- issue paid model requests to refresh a meter;
- render missing or expired data as `0%` or `$0.00`.

User consent does not turn a private credential store or an undocumented endpoint into a supported integration.

---

## 1. OpenAI Codex — local App Server

No public HTTP API exposes a person's ChatGPT/Codex subscription quota. `[F]` The documented local Codex App Server protocol does.

### 1.1 Transport and handshake

`[F]` `codex app-server` speaks JSON-RPC 2.0 *"with the `\"jsonrpc\":\"2.0\"` header omitted on the wire."* Transports:

- `stdio` (`--listen stdio://`, **default**): newline-delimited JSON (JSONL) — one message per line.
- Unix socket (`--listen unix://` or `--listen unix://PATH`): WebSocket over Codex's default app-server control socket or a custom path.
- WebSocket (`--listen ws://IP:PORT`): *"experimental and unsupported."*

Use **stdio JSONL**. Read line-delimited, parse each line independently, and never assume pretty-printed JSON or a `jsonrpc` member.

`[F]` *"Clients must send a single `initialize` request per transport connection before invoking any other method on that connection, then acknowledge with an `initialized` notification."*

```json
{ "method": "initialize", "id": 1,
  "params": { "clientInfo": { "name": "UsageTool", "title": "UsageTool", "version": "1.0.0" } } }
```
```json
{ "method": "initialized", "params": {} }
```

`[F]` Some methods and fields are gated behind an `experimentalApi` capability; without opting in the server rejects them with `<descriptor> requires experimentalApi capability`. The `account/rateLimits/*` methods are **not** marked experimental in the published API overview. `[I]` Therefore **do not** send `capabilities.experimentalApi: true` — opting in enlarges the unstable surface for no benefit. `[?]` Confirm no rate-limit sub-field is itself gated (§6, Q1).

### 1.2 Reading quota

```json
{ "method": "account/rateLimits/read", "id": 2 }
```

Subscribe to `account/rateLimits/updated` notifications for subsequent changes while connected.

`[F]` The result carries two overlapping views:

- `rateLimits` — *"the backward-compatible single-bucket view."*
- `rateLimitsByLimitId` — *"(when present) the multi-bucket view keyed by metered `limit_id` (for example `codex`)."*

**They overlap: the `codex` bucket appears in both.** Render rule, mandatory:

> If `rateLimitsByLimitId` is present, render from it **exclusively** and ignore `rateLimits`. Otherwise render `rateLimits` as a single bucket. Never render both — doing so duplicates every window.

Each bucket: `limitId`, `limitName` (nullable user-facing label), `primary`, `secondary` (either may be `null`), `rateLimitReachedType` (server-classified state once a limit is reached), and `planType` when the server returns the ChatGPT plan for that bucket.

Each window (`primary` / `secondary`) carries `[F]`:

| Field | Meaning | Unit |
|---|---|---|
| `usedPercent` | *"current usage within the quota window"* | percent, 0–100 |
| `windowDurationMins` | *"the quota window length"* | minutes |
| `resetsAt` | *"a Unix timestamp (seconds) for the next reset"* | epoch seconds |

Derivation for the UI's `UsageWindow.remainingFraction`:

```text
remainingFraction = clamp(1 - usedPercent / 100, 0, 1)
resetsAt          = Date(timeIntervalSince1970: resetsAt)
```

**Window labelling.** `[F]` Codex reports `primary`/`secondary` with a duration in minutes; it does **not** label them "5-hour" or "7-day". `[I]` Map to the UI's `WindowID` by duration — 300 min → `.fiveHour`, 10080 min → `.sevenDay` — and for any other duration render a generated label from `windowDurationMins` (e.g. "15-minute", "1-hour") rather than forcing it into a named slot. Never hard-code `primary == 5-hour`.

`[F]` `planType` supplies `Snapshot.plan` for the Codex block.

### 1.3 Fields that are not money

`[F]` `credits` *"is included when the server returns remaining workspace credit details."* `[F]` `rateLimitResetCredits` is a separate object holding *earned rate-limit reset* grants: `availableCount` is authoritative, and its `credits` array *"is null when only the count is known."*

These are two unrelated things. Neither is in v1 scope, and **neither may ever be rendered as a dollar amount**. Do not call `account/rateLimitResetCredit/consume` — it mutates account state.

### 1.4 `account/usage/read` — not in v1

`[F]` Returns token-activity summaries (`lifetimeTokens`, `peakDailyTokens`, `longestRunningTurnSec`, `currentStreakDays`, `longestStreakDays`) and optional `dailyUsageBuckets`. This is activity reporting, not subscription capacity. Out of v1 scope; the UI has no surface for it.

### 1.5 Authentication — UsageTool holds nothing

`[F]` Codex owns the entire sign-in ceremony. `account/login/start` with `type: "chatgpt"` returns an `authUrl`, and *"the app-server hosts the local callback"* (`redirect_uri=http://localhost:<port>/auth/callback`). A device-code flow (`type: "chatgptDeviceCode"`, returning `verificationUrl` + `userCode`) exists for when a browser callback is brittle.

**UsageTool does not invoke either flow in v1.** It reads quota from an already-signed-in Codex. If the user is not signed in, render `unavailable` with a "Sign in with `codex login` in Terminal" instruction. `[I]` Driving login from UsageTool would put the app in the middle of an OAuth ceremony it gains nothing from.

**Auth-mode caveats** — read `authMode` from `account/read` (or the `account/updated` notification) before every quota read:

`[F]` Documented modes: `apikey`, `chatgpt`, `chatgptAuthTokens`, `agentIdentity`, `personalAccessToken`, `bedrockApiKey`, or `null`.

- `null` → not signed in → `unavailable("Codex is not signed in")`.
- `apikey` / `bedrockApiKey` → API-platform billing, **not** subscription capacity. `[F]` For `account/usage/read` the docs state *"API-key-only and Bedrock auth don't [work]."* `[I]` The same constraint applies to rate-limit reads, which are documented as "Rate limits (ChatGPT)". Render `unavailable("Codex is signed in with an API key; subscription limits aren't reported")` rather than surfacing a protocol error. `[?]` Confirm the exact failure shape (§6, Q2).
- `chatgpt` / `personalAccessToken` / `agentIdentity` → supported.
- `chatgptAuthTokens` is a host-app mode requiring `experimentalApi` and supplied tokens. **Never use it** — it means holding a ChatGPT credential, which §0.3 forbids.

### 1.6 Maturity gate

`[F]` *"The app-server command and WebSocket transport are experimental and aren't supported for production workloads."*

Therefore:

- detect a `codex` executable and probe with `initialize` before claiming support;
- isolate all protocol decoding behind a `CodexAdapter` that can be disabled at runtime;
- fail to `unavailable` with an explanation and a link, never to scraped terminal output;
- keep contract fixtures for every accepted response shape, including a `rateLimitsByLimitId` response, a legacy `rateLimits`-only response, and a `secondary: null` response;
- surface the experimental status once in Settings › Providers › Codex, not as a recurring warning.

---

## 2. Anthropic Claude — Claude Code status-line adapter

No documented, independently pollable HTTP API exposes personal Claude Pro/Max remaining quota. `[F]` Claude Code passes subscription rate-limit data to a user-configured `statusLine` command on stdin.

### 2.1 Capability detection — no version gate

`[F]` The `rate_limits` object *"appears only for claude.ai Pro and Max subscribers, or behind a Claude apps gateway that sets a spend limit for you, and only after the first API response in the session."*

**Do not version-gate.** Claude Code's documentation attaches "Requires Claude Code v2.1.251 or later" to `rate_limits.spend_limit` and to `prompt_cache` — **not** to `five_hour`/`seven_day`, which appear in the documented example payload under `"version": "2.1.90"`. A 2.1.251 gate would wrongly declare working installations unsupported.

> Capability = the presence of `rate_limits.five_hour` or `rate_limits.seven_day` in a received payload. Nothing else.

### 2.2 Fields consumed

`[F]` Exactly three windows exist, and only two are in scope:

| Field | Meaning | Unit | In scope |
|---|---|---|---|
| `rate_limits.five_hour.used_percentage` | *"Percentage of the 5-hour … rate limit consumed, from 0 to 100"* | percent | yes |
| `rate_limits.five_hour.resets_at` | *"Unix epoch seconds when the … window resets"* | epoch seconds | yes |
| `rate_limits.seven_day.used_percentage` / `.resets_at` | as above, 7-day window | percent / epoch seconds | yes |
| `rate_limits.spend_limit.*` | Claude apps gateway spend limit | percent / epoch seconds | **no** (§2.3) |

`[F]` Behavior the adapter must honor:

- populated only after the session's first API response;
- *"Each window … may be independently absent"* → a missing window is `remainingFraction: nil` → UI `partial`, **never** `0`;
- *"Claude Code drops a window once its `resets_at` time passes"* → absence after a reset is expected, and must not be read as "100% remaining";
- `context_window.remaining_percentage` is **context capacity, not subscription quota** — the adapter must never emit it.

Derivation:

```text
remainingFraction = clamp(1 - used_percentage / 100, 0, 1)
resetsAt          = ISO8601(Date(timeIntervalSince1970: resets_at))
```

### 2.3 `spend_limit`: parse safely, do not report

`spend_limit` is a Claude apps gateway construct, not personal subscription capacity, and is out of scope per §0.2. `[F]` It matters here for one reason only: its *"percentage runs from 0 to 100, **or above 100 once you exceed the limit**."*

> The adapter must tolerate `used_percentage > 100` on any window without producing a negative fraction, an out-of-range value, or a crash, and must **drop** `spend_limit` rather than emit it. The `clamp` in §2.2 is mandatory, not defensive styling.

### 2.4 Fields that do not exist

Two things the UI spec anticipates are **not** available from the documented status-line JSON `[F]`:

- **A Claude plan name.** No subscription-plan field is documented. The adapter must emit `plan: null`, and the Claude block must hide the plan chip rather than invent one. (Codex does supply `planType`; Claude does not.)
- **Per-model 7-day windows.** Only `five_hour`, `seven_day` and `spend_limit` exist. `model.display_name` is the *current session's* model, not a per-model quota. The `model:<name>` window ID in the UI spec's adapter contract has no documented source and must not be emitted in v1. `[?]` See §6, Q3.

### 2.5 Adapter contract

The adapter is a small user-installed executable configured as Claude Code's `statusLine` command. It reads the status JSON on stdin, extracts only the fields in §2.2, writes a sanitized snapshot, and prints a short human-readable line to stdout (chaining any pre-existing status line unchanged).

Output file — `~/Library/Application Support/UsageTool/claude-usage.json`, matching `Design/UsageTool-UI-Spec.md` §7.5:

```json
{
  "schema": 1,
  "reportedAt": "2026-09-19T10:14:22Z",
  "sessionId": "<session_id from stdin>",
  "plan": null,
  "windows": [
    { "id": "5h", "remainingFraction": 0.42, "resetsAt": "2026-09-19T11:19:00Z" },
    { "id": "7d", "remainingFraction": 0.18, "resetsAt": "2026-09-22T09:00:00Z" }
  ]
}
```

The adapter writes **nothing else**: no session transcript path, working directory, cost, context, prompt-cache, git or PR fields, and no credentials of any kind. `sessionId` is included solely for the last-writer-wins rule below.

**Atomic write, mandatory.** `[F]` Claude Code *"cancels the in-flight script"* if a new update triggers while it is still running, and its own documentation warns that concurrent sessions share files. Consequences:

1. Write to a temporary file **in the same directory** and `rename(2)` into place. A partially written snapshot must never be observable.
2. Multiple concurrent Claude Code sessions each run the adapter against the same path. `rate_limits` is account-level, so the values agree; ordering does not. Apply **last-writer-wins on `reportedAt`**: the reader ignores a snapshot whose `reportedAt` is older than the one it already holds.
3. The reader must tolerate a zero-length, truncated or momentarily absent file without entering an error state — treat it as "no new data" and keep the previous snapshot.

### 2.6 Freshness

`[F]` The status line re-runs when: a new assistant message arrives, `/compact` finishes, permission mode changes, vim mode toggles, the `command` setting changes, **a `refreshInterval` timer elapses**, or **a rate-limit window in the last received data reaches its `resets_at` time**. Updates are debounced at 300 ms.

`[F]` *"The optional `refreshInterval` field re-runs your command every N seconds … The minimum is `1`."* `[F]` *"The event-driven triggers can go quiet when the main session is idle."*

Therefore the installed configuration sets a `refreshInterval` of **60–300 seconds**:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/Library/Application Support/UsageTool/bin/usagetool-statusline --chain '<existing command, if any>'",
    "refreshInterval": 120
  }
}
```

`[F]` The status line *"runs locally and does not consume API tokens."*

UsageTool watches the snapshot file (`DispatchSource` on the file, plus a low-frequency stat fallback) and never polls Anthropic. **The data only updates while a Claude Code session is running** — between sessions the last report ages into `stale`, and a passed `resetsAt` expires the window to "not reported". Neither condition ever renders as `100%`.

### 2.7 Credential and policy position

UsageTool collects, stores and transmits **no Claude credentials**. It makes no network request to Anthropic at all.

What the published sources actually say `[F]`:

- *"The preferred way to access Anthropic services using third-party software, tools, or services … is through API key authentication through Claude Console or a supported cloud provider."*
- *"Anthropic may … allow paid subscribers … to use certain third-party tools to access Anthropic services included in paid subscription plans, but reserves the right to draw use of such third-party tools from usage credits rather than subscription limits."*
- *"Applications that misrepresent their identity to Anthropic's servers, attempt to route third-party traffic against subscription limits, or otherwise violate applicable terms or policies are prohibited and may be enforced against."*
- Consumer Terms: *"You may not share your Account login information, Anthropic API key, or Account credentials with anyone else or make your Account available to anyone else."*

Precise reading: credential sharing, extraction and proxying are prohibited outright; running a third-party tool against subscription capacity is **conditionally permitted at Anthropic's discretion**, not banned. UsageTool does not depend on that discretion — it issues no Anthropic traffic and holds no credential; it reads a file that the user's own Claude Code wrote at the user's instruction.

Accordingly UsageTool must not: offer "Sign in with Claude"; request or store Claude OAuth/session tokens; read `~/.claude` credentials or Claude Code Keychain items; call private Claude endpoints; or present an Anthropic API key as if it were Pro/Max quota. The UI must expose no Claude key or sign-in control at all.

---

## 3. OpenRouter — account credits

v1 is **credits-only**. Ordinary-key limit reporting and OAuth PKCE are out of scope (§0.2).

### 3.1 Balance

```http
GET https://openrouter.ai/api/v1/credits
Authorization: Bearer <OPENROUTER_MANAGEMENT_KEY>
```

`[F]` Response:

```json
{ "data": { "total_credits": 100.50, "total_usage": 25.75 } }
```

`total_credits` is *"Total credits purchased"*; `total_usage` is *"Total credits used"*. Both are cumulative lifetime figures in USD.

```text
remainingCreditsUSD = total_credits - total_usage
```

Show the dollar balance alone. **Never** derive a percentage: `remaining / total_credits` is a fraction of cumulative lifetime funding, not a recurring allowance. The two totals appear only as plainly labeled values in the expanded detail (`Design/UsageTool-UI-Spec.md` §6, §14).

`[F]` A missing `total_credits` or `total_usage` is a parse/network error, not `partial`.

`[F]` OpenRouter Terms §4.2: *"OpenRouter reserves the right to expire unused credits three hundred sixty-five (365) days after purchase."* `[I]` Label the figure as the balance **reported by** the credits API; do not present it as a guarantee of spendable funds.

`[F]` Errors: `401` missing authentication header; `403` *"Only management keys can perform this operation"*; `500` internal error.

### 3.2 Management key: privilege, verification, expiry

`[F]` *"Management keys cannot be used to make API calls to OpenRouter's completion endpoints - they are exclusively for administrative operations."* `[F]` *"A leaked management key could create, edit and delete the API keys in your account other than those provisioned by a Connect client."*

`[F]` Key creation takes only a name and an expiration — **there is no balance-only scope to request.** This is why UsageTool must disclose the privilege before collecting the key (`Design/UsageTool-UI-Spec.md` §7.7) rather than asking for something narrower.

**Verification.** `GET https://openrouter.ai/api/v1/key` with the pasted key, on connect and cheaply on refresh:

`[F]` Relevant response fields: `is_management_key: boolean`, `expires_at: date-time | null`, `label: string`. (`is_provisioning_key` is deprecated — use `is_management_key`.)

- `is_management_key == false` → reject at entry with `authError("Not a management key")`. Never let the user discover this via a 403.
- `expires_at` → store with the connection; drives the expiring/expired states below.
- `label` → the key name for the detail grid.

**Expiry — mandatory handling.** `[F]` *"The expiration is fixed when the key is created and cannot be changed afterwards. To extend access, create a new key and delete the old one."* `[F]` *"Once a key's expiration passes, every request that uses it fails with `401 Unauthorized` and the message `API key expired`."*

| Condition | State | Remedy text |
|---|---|---|
| `expires_at` within 7 days | `connected` + expiring pill | "Key expires in Nd — create a new one" |
| `expires_at` in the past, or `401` with `API key expired` | `credentialExpired` | **"Create a new management key"** — an expired key cannot be extended |
| `401` without `API key expired`, or `403` | `authError` | "Key rejected — check or replace it" |

`[F]` `expires_at` may be `null` (no expiry). Treat that as valid but surface it in the detail grid, since OpenRouter *recommends* setting an expiry on every management key.

### 3.3 Credential handling

- Store as a Keychain generic-password item (§4.3). One item; there is no second key type in v1.
- Never place the key in `UserDefaults`, a URL, a log, analytics, a diagnostic bundle, a screenshot or a crash report.
- Redact every `Authorization` header and the key `label` from any diagnostic output.
- Delete the Keychain item on disconnect.
- Link revocation and creation directly: `https://openrouter.ai/settings/management-keys`.

`[F]` OpenRouter Terms §7 prohibits scraping and bypassing technical measures, and §3.2 makes the account holder responsible for all activity under their API credentials — both consistent with §0.3.

---

## 4. Shared contract: refresh, state, security

### 4.1 Refresh

OpenRouter (the only polled HTTP interface):

- 5–15 minute interval with jitter; one global cadence (`Design/UsageTool-UI-Spec.md` §15);
- manual refresh with coalescing — concurrent requests share one in-flight call;
- pause while asleep or offline; refresh once after wake and after network recovery;
- honor `Retry-After`; exponential backoff on `429` and `5xx`;
- **stop automatic retries on `401`/`403` until the user acts** — retrying a rejected or expired key accomplishes nothing and looks like an attack.

Codex: read once on connect, then consume `account/rateLimits/updated` notifications while the connection is live. Re-read after reconnect. Do not poll on a timer while connected.

Claude: never polled. File-watch only (§2.6).

Never issue a model request to refresh a meter, on any provider.

### 4.2 State

The state model is owned by `Design/UsageTool-UI-Spec.md` §5 (`disconnected`, `loading`, `connected`, `stale`, `partial`, `unavailable`, `authError`, `credentialExpired`, `networkError`). This brief adds only the provider-side rules that produce them:

- Missing value → `nil` → `—`, never `0%` / `$0.00`.
- A passed reset timestamp expires the window; it never implies full remaining capacity.
- Distinct windows stay distinct; never synthesize a combined total.
- Every displayed value carries source, observation time, and reset time.
- Any user-entered fallback value is labeled "Manual" and never mixed with reported data.

### 4.3 macOS security, for **direct Developer ID distribution**

**Distribution decision (settled):** Developer ID, notarized, Hardened Runtime enabled, distributed outside the Mac App Store. **App Sandbox is out of scope.** Mac App Store review rules are therefore not product blockers and are not tracked here; earlier guidance about sandbox entitlements, security-scoped bookmarks and Guideline 2.5.2 has been removed rather than caveated.

`[F]` *"To upload a macOS app to be notarized, you must enable the Hardened Runtime capability."*
`[F]` *"The Hardened Runtime doesn't affect the operation of most apps, but it does disallow certain less common capabilities, like just-in-time (JIT) compilation."*
`[I]` UsageTool needs **no** Hardened Runtime exception entitlements: it performs no JIT, loads no third-party plug-ins, and spawning a separately signed executable is not a restricted capability. Adding an exception entitlement without a proven need weakens the build — `[F]` Apple: *"Make sure to use only the entitlements that are absolutely necessary."*

**Process model for Codex.** `[I]` Unsandboxed, UsageTool may launch the user's installed `codex` binary directly over stdio. Required discipline:

- resolve the executable explicitly (a user-configurable path, defaulting to a `PATH` lookup) and record which path was used in diagnostics;
- do not pass the user's full environment blindly; pass a minimal environment;
- treat the child as untrusted input: bounded line length, bounded buffer, hard timeout on `initialize`, and termination of the child on disconnect or app quit;
- never write to the child's stdin anything derived from network input.

**Keychain.** Use Security.framework directly — `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete` with `kSecClassGenericPassword` and an app-owned service identifier. `[F]` Apple: *"It's highly recommended that you set the value of this key [`kSecUseDataProtectionKeychain`] to `true` for all keychain operations."* Set it. `[F]` Keychain sharing grants access only among appropriately entitled targets from the same developer — it is never a route to another vendor's items.

**Architecture.** Keep a least-privilege provider-adapter boundary: adapters own credentials and raw responses; view models receive normalized, non-secret snapshots.

```swift
struct UsageSnapshot {
    let provider: Provider
    let source: DataSource
    let observedAt: Date          // when UsageTool obtained it
    let reportedAt: Date?         // when the source produced it (Claude adapter)
    let state: FreshnessState
    let plan: String?             // Codex planType; nil for Claude (§2.4)
    let metrics: [UsageMetric]
}

struct UsageMetric {
    let id: WindowID              // .fiveHour, .sevenDay, .other(minutes: Int)
    let label: String             // limitName, or derived from windowDurationMins
    let usedPercent: Double?      // raw, unclamped — preserved for diagnostics
    let remainingFraction: Double? // nil = not reported → dotted track + "—"
    let windowDurationMins: Int?  // Codex only
    let resetsAt: Date?
}
```

Do not persist raw provider responses. If snapshots are cached, retain only normalized non-secret fields plus `observedAt`.

---

## 5. v1 scope

1. **OpenRouter** — account credits via `/api/v1/credits` with a verified, expiry-tracked management key. Ship first; it is the only fully documented, stable HTTP interface in the product.
2. **Claude** — the user-enabled status-line adapter. Ship second; no credentials, no network calls, self-contained.
3. **Codex** — local App Server over stdio JSONL, behind a removable adapter and labeled experimental. Ship last.
4. **Fallbacks** — every provider offers a direct link to its official usage view when live data is unavailable:
   - OpenRouter credits: `https://openrouter.ai/settings/credits` `[F]` (verified)
   - OpenRouter keys: `https://openrouter.ai/settings/management-keys` `[F]` (verified; redirects to sign-in when signed out)
   - Codex usage: the ChatGPT/Codex usage page `[?]` — bot-protected against automated checking; verify the exact URL in a browser before shipping (§6, Q4)
   - Claude usage: the Claude.ai usage settings page `[?]` — same caveat (§6, Q4)
5. **Menu bar** — percentages and dollar values may be independently enabled; a stale or unknown value always carries a visible qualifier and is never silently retained as a current number.

---

## 6. Unresolved implementation questions

| # | Question | Blocks | How to resolve |
|---|---|---|---|
| Q1 | Is any field inside `account/rateLimits/read` gated behind `experimentalApi`, such that omitting the capability silently drops data? | Codex adapter | Call `initialize` without the capability, diff the result against a call with it, on a live signed-in Codex. |
| Q2 | What exactly does `account/rateLimits/read` return when `authMode` is `apikey` or `bedrockApiKey` — an error, or an empty/`null` `rateLimits`? | Codex `unavailable` copy | Sign in with an API key and call it. The docs state the constraint only for `account/usage/read`. |
| Q3 | `Design/UsageTool-UI-Spec.md` §1 and §6 list a **per-model 7-day window** and a **plan name** for Claude. Neither exists in the documented status-line JSON (§2.4). Does the design drop them, or is another source intended? | Claude block layout, adapter schema | Product decision. Recommended: drop both from the Claude block for v1 — the adapter cannot supply them without violating §0.3. |
| Q4 | Exact, current URLs for the ChatGPT/Codex usage page and the Claude.ai usage page. | Fallback links | Open each in a browser and copy the canonical URL; both refuse automated requests. |
| Q5 | Does an installed `codex` reliably expose `account/rateLimits/read` across the versions users actually have, and what is the oldest version to claim support for? | Codex version gate | Probe `initialize` + `account/rateLimits/read` across two or three Codex releases; record a minimum version in the adapter. |

---

## 7. Acceptance checklist

**Boundary**
- [ ] No dashboard scraping, no private endpoints; `/backend-api/wham/usage` appears nowhere in the codebase.
- [ ] No import or reading of Codex or Claude credential files or Keychain items.
- [ ] No Claude sign-in, OAuth, or API-key control exists in the UI.
- [ ] No organization/Admin usage or cost API is called; no Admin key field exists (§0.2).
- [ ] No model request is ever issued to refresh a meter.

**Codex**
- [ ] stdio JSONL framing; `jsonrpc` member absent on the wire; per-line parsing.
- [ ] `initialize` → `initialized` before any other method; `experimentalApi` **not** requested.
- [ ] `rateLimitsByLimitId` preferred, legacy `rateLimits` as fallback, **never both**.
- [ ] Window labels derived from `windowDurationMins`; `primary` is not assumed to be the 5-hour window.
- [ ] `resetsAt` parsed as Unix epoch **seconds**.
- [ ] `authMode` checked before each read; `apikey`/Bedrock render `unavailable`, not an error.
- [ ] `credits` and `rateLimitResetCredits` are never rendered as money.
- [ ] Child process: explicit executable path, minimal environment, bounded buffers, handshake timeout, terminated on quit.
- [ ] Fixtures cover multi-bucket, legacy-only, and `secondary: null` responses.

**Claude**
- [ ] No version gate; capability = presence of `rate_limits.five_hour` or `.seven_day`.
- [ ] `used_percentage > 100` cannot produce a negative or out-of-range fraction; `spend_limit` is parsed safely and dropped.
- [ ] Adapter emits only schema/reportedAt/sessionId/plan/windows; `plan` is `null`; no `model:` windows.
- [ ] `context_window.*` is never emitted or displayed as quota.
- [ ] Snapshot written via temp file + `rename(2)`; reader survives truncated, empty and absent files.
- [ ] Last-writer-wins on `reportedAt` across concurrent sessions.
- [ ] Installed config sets `refreshInterval` (60–300 s) and chains any pre-existing status line.
- [ ] A missing window renders `partial`; a passed `resets_at` expires the window; neither becomes `100%`.

**OpenRouter**
- [ ] `/api/v1/key` verifies `is_management_key` at entry; a non-management key is rejected before any 403.
- [ ] `expires_at` stored; expiring (≤ 7 d) and expired states implemented with the "create a new key" remedy.
- [ ] `401 API key expired` distinguished from other auth failures.
- [ ] No percentage is derived from `total_credits`; no ordinary-key or PKCE path exists.
- [ ] Automatic retries stop on `401`/`403`.

**Platform**
- [ ] Developer ID signed, notarized, Hardened Runtime enabled, no exception entitlements.
- [ ] Secrets in the Keychain with `kSecUseDataProtectionKeychain: true`; redacted from every log, diagnostic and crash report.
- [ ] Missing or expired data never renders as zero.
- [ ] Source and last-observed time visible for every displayed value.
- [ ] All fallback links verified to resolve (§6, Q4).
- [ ] Linked documentation and terms re-reviewed before public release.

---

## 8. Official sources

All URLs verified to resolve on 2026-09-19 unless noted.

### OpenAI
- Codex App Server protocol: https://learn.chatgpt.com/docs/app-server
  *(the older `developers.openai.com/codex/app-server` 308-redirects here)*

### Anthropic
- Claude Code status line: https://code.claude.com/docs/en/statusline
- Claude Code settings: https://code.claude.com/docs/en/settings
- Third-party access and authentication guidance: https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account
- Consumer Terms: https://www.anthropic.com/legal/consumer-terms

### OpenRouter
- Get remaining credits: https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits
- Get current API key: https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key
- Management API keys: https://openrouter.ai/docs/guides/overview/auth/management-api-keys
- Terms of Service: https://openrouter.ai/terms
- Management keys settings: https://openrouter.ai/settings/management-keys
- Credits page: https://openrouter.ai/settings/credits

### Apple
- Keychain Services: https://developer.apple.com/documentation/security/keychain-services
- Adding a password to the Keychain: https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain
- `kSecUseDataProtectionKeychain`: https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

### Removed in revision 2
OpenAI Usage/Admin-key references, Anthropic Usage & Cost API references, OpenRouter OAuth PKCE references, and App Sandbox / security-scoped bookmark references have been deleted rather than caveated — all are out of scope per §0.2 and §4.3. A dead OpenRouter OAuth citation (`…/o-auth/exchange-auth-code-for-api-key`, HTTP 404) was removed with them.
