# UsageTool — Session Handoff

**Updated:** 2026-09-19  
**Workspace:** `/Users/michaelvassiliadis/Development/experiments/UsageTool`  
**Current phase:** Research and design are finalized and validated; implementation has not started.

## Resume first

1. Read this file completely.
2. Read `Research/Service-Integration-Research.md` completely.
3. Read `Design/UsageTool-UI-Spec.md` completely.
4. Inspect the rendered mockups:
   - `Design/UsageTool-Popover.png`
   - `Design/UsageTool-Settings.png`
5. Use the Herdr skill before controlling panes. This work is running inside Herdr.

## Product

Build a native **macOS 27** Swift utility that lives in the menu bar. Clicking an item opens a compact popover showing:

- personal OpenAI Codex subscription windows as percentage remaining;
- personal Claude subscription windows as percentage remaining; and
- OpenRouter account credits remaining in USD.

The UI must be modern, simple, native, and polished without becoming bland. Numbers are the visual priority. Users can optionally expose separate menu-bar items such as `Codex 73%`, `Claude 42%`, and `$18.20`.

Settings provide provider setup, refresh/freshness settings, menu-bar formatting, launch at login, and privacy/status information.

## Settled platform decisions

- Minimum and primary target: **macOS 27**.
- Toolchain detected: Xcode 27.0, macOS SDK 27.0, Swift 6.4.
- SwiftUI first; AppKit only where needed.
- Direct distribution as a Developer ID signed/notarized app.
- Hardened Runtime enabled.
- **No Mac App Store requirement and no App Sandbox requirement.**
- `LSUIElement = YES` menu-bar utility.
- Native/standard Apple technologies; avoid unnecessary third-party dependencies.
- Workspace is **not yet a Git repository**.

## Settled service integrations

### Codex

Use only the documented local Codex App Server.

- Launch the configured user-installed `codex` executable with Foundation `Process`.
- Use newline-delimited JSON over `codex app-server --listen stdio://`.
- Perform `initialize` then `initialized` before other methods.
- Read `account/rateLimits/read`; consume `account/rateLimits/updated` notifications.
- If `rateLimitsByLimitId` exists, use it exclusively; otherwise use legacy `rateLimits`. Never render both.
- App Server/Codex owns ChatGPT authentication. UsageTool must never read or store Codex credentials.
- Never use the Pi plugin’s private `https://chatgpt.com/backend-api/wham/usage` approach.
- Never parse interactive CLI output or scrape a dashboard.
- Organization API usage/cost endpoints are out of scope.

### Claude

Use only a user-enabled Claude Code `statusLine` adapter.

- Claude Code passes status JSON to the adapter on stdin.
- The adapter retains only `rate_limits.five_hour` and `rate_limits.seven_day`, derives remaining percentages, and atomically writes a sanitized snapshot.
- No Claude OAuth token, API key, cookie, credential file, dashboard request, or private endpoint.
- No Claude subscription plan name and no per-model quota: the documented export provides neither.
- Parse and drop `spend_limit`; it is a gateway spend limit, not personal subscription capacity.
- Preserve/chain any existing status-line command rather than overwriting it silently.
- Never modify the user’s actual `~/.claude/settings.json` during automated tests. Use temporary fixture homes/paths.

### OpenRouter

V1 is account credits only.

- `GET https://openrouter.ai/api/v1/key` validates `is_management_key` and reads `expires_at`.
- `GET https://openrouter.ai/api/v1/credits` reads `total_credits` and `total_usage`.
- Remaining USD = `total_credits - total_usage`.
- Store the management key in Keychain. Never log it.
- Disclose that management keys can administer account API keys and that no balance-only scope is documented.
- Handle pre-expiry and expired-key states.
- Do not implement ordinary-key limits, PKCE, key usage, percentages, or per-model spend.

## Non-negotiable data/UI behavior

- Missing, unsupported, stale, expired, partial, and error are distinct states.
- Missing data is `—` / unavailable, never `0%`.
- Passing a reset timestamp expires the snapshot; it does not fabricate `100%`.
- Display each quota window independently.
- Codex and Claude numbers are **remaining**, not used. Convert documented used percentages with `clamp(100 - used, 0, 100)`.
- OpenRouter is a dollar balance; do not derive a percentage/bar from cumulative credits.
- Show source/provenance and observation time.
- Keep secrets out of UserDefaults, logs, URLs, telemetry, crash reports, and tests.
- Store OpenRouter secrets with Security.framework Keychain APIs.

## Durable artifacts

- `Research/Service-Integration-Research.md` — reviewed and reconciled implementation research.
- `Design/UsageTool-UI-Spec.md` — full UI/UX and SwiftUI/AppKit mapping.
- `Design/UsageTool-Popover.svg` / `.png` — popover visual artifact.
- `Design/UsageTool-Settings.svg` / `.png` — settings visual artifact.
- `Design/Assets/ProviderIcons/` — official-provider icon pass currently being completed by Fable.

## Live Herdr agents

Workspace/tab at handoff: `wJ` / `wJ:t1`.

### `ui-designer` — pane `wJ:p5`

- Claude Fable, high effort.
- Idle; all design work is complete and validated.
- It sourced first-party OpenAI, Claude, and OpenRouter marks, documented provenance/trademark caveats, updated the specification and mockups, and produced opaque 2× PNGs.
- Final assets:
  - `Design/Assets/ProviderIcons/openai-logomark.svg`
  - `Design/Assets/ProviderIcons/claude-spark-clay.svg`
  - `Design/Assets/ProviderIcons/openrouter-glyph-{cloud,grape,ink,volt}.svg`
  - `Design/Assets/ProviderIcons/README.md`
- All SVGs pass `xmllint`; asset safety scans found no scripts, event handlers, `foreignObject`, external references, or raster payloads. The only URL strings in the raw SVGs are normal XML namespace declarations.

### `service-review` — pane `wJ:p6`

- Claude Opus 5.
- Idle; review/reconciliation is complete.
- The final research brief contains five unresolved implementation questions in §6. Four are implementation/browser compatibility spikes. The former product issue—unsupported Claude plan/per-model fields—has already been removed from all design artifacts.

## Current render checks

At handoff, after Fable’s opacity correction began:

```text
Design/UsageTool-Popover.png: 2680×1580, opaque=True, alpha=[1,1]
Design/UsageTool-Settings.png: 3800×1760, opaque=True, alpha=[1,1]
```

The final icon-integrated PNGs were visually verified: the light and dark artboards render correctly, every artboard is present, and nothing is clipped.

## Task state

- Completed: service research.
- Completed: initial UI design.
- Completed: Opus service review and research reconciliation.
- Completed: removal of unsupported Claude plan/per-model fields.
- Completed: official provider icons and final opaque renders.
- Pending: implementation with Codex (`gpt-5.6-sol`, high reasoning).
- Pending: independent review, build, tests, diagnostics, and fixes.

## Immediate next steps

1. Read and verify the finalized durable artifacts listed above.
2. Transition the finished right-side panes into the requested full-height vertical implementation pane. A practical layout is to close the finished service-review pane, end the Fable session, and reuse/expand `wJ:p5` for a fresh Claude Code implementation session.
3. Start a fresh Codex implementation agent using `gpt-5.6-sol` with high reasoning and edit permissions, named `implementation`.
4. Tell it to read this handoff, the complete research brief, the complete UI spec, icon README, and mockups before writing code.
5. Require milestone updates and builds/tests throughout; continue reporting progress often.

## Implementation milestones

1. Create a native Xcode project/scheme and initialize Git.
2. Implement domain models, normalized provider states, settings persistence, and Keychain wrapper.
3. Implement Codex App Server JSONL process/protocol adapter with fixtures/tests.
4. Implement the Swift Claude status-line helper, sanitized atomic snapshot contract, configuration backup/merge/restore flow, and tests using temporary fixtures only.
5. Implement OpenRouter management-key validation/expiry and credits client with mocked URLProtocol tests.
6. Implement shared store, refresh/backoff/staleness behavior, menu-bar scenes, popover, settings, accessibility, light/dark behavior, and official icon assets.
7. Build with `xcodebuild`, run unit/UI-relevant tests, run diagnostics, and fix all failures.
8. Independently review security, compliance boundaries, secret handling, process lifecycle, JSON decoding, and UX state correctness.

## Validation expectations

- Build cleanly with the installed Xcode 27/macOS 27 SDK.
- Use strict Swift concurrency safely.
- No live provider calls or real credential/config modifications in automated tests.
- No private service endpoints anywhere in source.
- No secrets in fixtures or logs.
- Verify all documented error/stale/partial/expired states.
- Verify menu-bar icon-only, combined summary, and independent provider items.
- Re-check official documentation links before release.

## User coordination requirements

- Implementation must be performed by a Codex instance using `gpt-5.6-sol` with high reasoning in a vertical Herdr pane.
- Monitor it rather than leaving it unattended.
- Report progress frequently.
