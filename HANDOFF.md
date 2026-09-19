# UsageTool — Session Handoff

**Updated:** 2026-09-19
**Workspace:** `/Users/michaelvassiliadis/Development/experiments/UsageTool`
**Current phase:** Native implementation and unsigned local validation are complete. Real-provider testing is in progress; the Claude adapter installer crash found during hands-on testing is fixed. Signing/notarization is intentionally deferred.

## Resume first

1. Read this file completely.
2. Read `README.md` for build/test instructions.
3. Read `Documentation/Manual-Verification.md` before changing menu-bar scene bindings.
4. Read `Research/Service-Integration-Research.md` and `Design/UsageTool-UI-Spec.md` before changing provider or product behavior.
5. Use the Herdr skill before controlling panes. This work is running inside Herdr.

## Repository state

- Git repository initialized on `main`.
- Initial implementation commit: `f794fb7` (`Initial UsageTool implementation`).
- Xcode project: `UsageTool.xcodeproj`.
- Targets: native UsageTool app, bundled `usagetool-statusline` helper, and `UsageToolTests`.
- Minimum/primary target: macOS 27; Xcode 27; Swift 6.4.
- SwiftUI-first, `LSUIElement = YES`, Hardened Runtime enabled, no App Sandbox.
- Signing, notarization, and signed-Keychain entitlement validation are deferred by user direction.

## Product

UsageTool is a native macOS menu-bar utility showing:

- personal OpenAI Codex subscription windows as percentage remaining;
- personal Claude subscription windows reported by Claude Code; and
- OpenRouter account credits remaining in USD.

The normal app exposes a main menu-bar item plus optional independent provider items. Clicking an item opens the shared popover; Settings controls providers, refresh/freshness, menu-bar formatting, launch at login, and privacy/status information.

## Implemented service integrations

### Codex

Implemented through the documented local Codex App Server only:

- Foundation `Process`, stdio JSONL, bounded framing/buffers, handshake timeout, ordered chunk consumption, reconnect policy, and synchronous quit cleanup.
- `initialize` → `initialized` before requests.
- `account/read`, `account/rateLimits/read`, and `account/rateLimits/updated`.
- `rateLimitsByLimitId` exclusively when present; legacy `rateLimits` fallback otherwise.
- Dynamic window durations: Codex does not need to report a 5-hour window. Unknown durations receive generated labels and are displayed independently.
- Current App Server account shape accepts documented `authMode` and the empirically observed `account.type` form.
- No Codex credential files are read; no model request is issued.

Executable handling was hardened after real-GUI testing:

- Automatic discovery covers GUI `PATH`, standard prefixes, NVM/FNM, Volta, nodenv, asdf, and `n` installs.
- Settings › Providers › Codex exposes an explicit executable field, **Choose…**, **Automatic**, and resolved-path/origin feedback.
- A broken explicit path is reported rather than silently replaced.
- The child receives a minimal allow-listed environment whose `PATH` includes the launcher and shebang interpreter directories, allowing npm/NVM `#!/usr/bin/env node` launchers to work.
- The old persisted `/usr/local/bin/codex` default migrates to automatic discovery.
- A real GUI-minimal environment successfully discovered and launched the installed NVM Codex App Server without reading credentials or issuing model requests.

### Claude

Implemented through the user-enabled Claude Code `statusLine` adapter only:

- Bundled Swift helper reads stdin and retains only sanitized 5-hour/7-day usage windows.
- `spend_limit`, model, context, cost, paths, session identifiers, and credentials are dropped.
- Atomic snapshot writes and tolerant/last-writer-wins reads.
- Existing status-line commands are chained and preserved across install, reinstall, removal, and recovery from missing manifests.
- Guided install backs up and merges only `statusLine`; unsupported configuration fails closed to manual instructions.
- Automated tests use temporary homes and never modify the real `~/.claude/settings.json`.
- Real Claude configuration mutation remains user-initiated only and is never used by automated validation.
- A user-initiated guided install has now been exercised against the real local Claude settings and the post-fix flow completes without crashing.

### OpenRouter

Implemented for account credits only:

- `/api/v1/key` validates management-key status and expiry.
- `/api/v1/credits` reads cumulative credited/used amounts; remaining USD is their difference.
- Management key stored through Security.framework Keychain with data-protection Keychain enabled.
- Expiring, expired, auth, retry/backoff, `Retry-After`, coalescing, and stop-on-401/403 behavior implemented.
- URL transport is mocked in tests; no live key or provider request is used during automated validation.
- No ordinary-key mode, PKCE, percentages, key usage, or per-model spend.

## Non-negotiable behavior

- Missing, unsupported, stale, expired, partial, loading, auth, and network error remain distinct states.
- Missing data is `—`, never `0%` or `$0.00`.
- Passing a reset timestamp expires a window; it never fabricates `100%`.
- Codex/Claude values are remaining percentages; used percentages are clamped and inverted.
- OpenRouter is a dollar balance and never receives a percentage/bar.
- Source/provenance and observation time remain visible.
- Secrets stay out of UserDefaults, logs, URLs, telemetry, crash reports, and fixtures.

## Important runtime fixes

### Menu-bar scene live-lock

The first real app launch produced a blank/dead menu-bar slot. Root cause: `MenuBarExtra(isInserted:)` writes its value back during scene updates, while the original binding setters unconditionally mutated `@Observable` preferences and normalization rewrote them. That created an `AppGraph.graphDidChange()` feedback loop before status-item installation.

Fixes:

- Menu-bar insertion setters are strict no-ops when the value is unchanged.
- Preference normalization and persistence are idempotent.
- Settings explicitly activates the accessory app when shown so its window appears in front.
- Regression coverage lives in `Tests/UsageToolTests/MenuBarSceneTests.swift`.
- Manual checks and the invariant are documented in `Documentation/Manual-Verification.md`.

Do not introduce observable mutations from scene-level binding getters/setters without preserving this invariant. A healthy idle app uses approximately 0% CPU.

### Claude adapter installer queue crash

The first real guided Claude adapter install committed `statusLine` and copied the helper, then trapped with a libdispatch main-queue assertion while the manifest atomic write notified the active snapshot watcher. The dispatch-source event handler had inherited `MainActor` isolation even though Dispatch executed it on a utility queue.

Fixes:

- The watcher uses an explicitly `@Sendable` dispatch handler and enters `MainActor` through a `Task` before touching watcher/UI state.
- Guided install/reinstall stages the helper and rolls back helper, settings, manifest, and newly created backup when a later step fails.
- A failed settings rollback retains the recovery backup and reports both the original error and backup path.
- The setup sheet keeps state mutations on `MainActor` and prevents overlapping install/remove actions.
- Regression coverage exercises an active watcher, manifest-write failure, reinstall rollback, failed settings restoration, stale atomic-write manifest artifacts, and transaction cleanup.

A stale `claude-adapter-install.json.sb-*` file from an interrupted Foundation atomic write is not treated as a valid manifest. Abrupt process termination can still leave a staged helper artifact because the operation has no persistent journal, and adapter removal remains non-transactional; both are non-blocking residual risks.

### Safe local preview

A compile-time-only validation variant provides deterministic popover/settings windows with in-memory settings/secrets and disabled providers. It intentionally uses a normal `WindowGroup`; it does not exercise `MenuBarExtra`. See:

- `Documentation/Local-Validation.md`
- `Documentation/Local-Validation-Report.md`

Use the normal Debug app plus `Documentation/Manual-Verification.md` for real menu-bar/popover/Settings testing.

## Validation completed

- Debug and Release builds completed successfully under Xcode 27/macOS 27.
- Swift strict-concurrency build is clean.
- Final suite after the Claude installer fix: **74/74 tests pass**.
- Focused Claude coverage passes **14/14 tests**.
- The Hardened Runtime Debug build passes, and `git diff --check` is clean.
- Earlier repeated checkpoint runs also completed without failures.
- Deterministic coverage includes domain/state rules, Codex JSONL/process/discovery/auth, Claude sanitization/configuration, OpenRouter mocked transport/retry/auth, and menu-bar binding invariants.
- Normal app manually verified: visible template icon, popover click, Settings gear, summary/separate items, idle CPU, quit cleanup, and a successful user-initiated Claude guided install after the fix.
- Safe preview manually inspected populated, error, empty, settings, light, and dark states.
- Independent Claude Opus review accepted the installer fix and follow-up remediations with no remaining blocking, high, or medium findings.
- No private service endpoints or provider credential-file access exist in production source.

## Known environment diagnostics

These are host/toolchain noise, not UsageTool failures:

- Xcode repeatedly reports `DVTCoreDeviceCore`/CoreSimulator version mismatch because the installed system CoreSimulator framework is older than the Xcode 27 component. Native macOS builds/tests still pass.
- macOS may log `com.apple.linkd.autoShortcut` XPC connection errors during launch. UsageTool defines no App Intents, and menu-bar behavior works independently of these messages.

Do not delete or replace system private frameworks to suppress these diagnostics.

## Durable artifacts

- `Research/Service-Integration-Research.md` — reviewed integration research and unresolved external checks.
- `Design/UsageTool-UI-Spec.md` — UI/UX specification.
- `Design/UsageTool-Popover.*`, `Design/UsageTool-Settings.*` — visual artifacts.
- `Design/Assets/ProviderIcons/` — official provider marks and provenance.
- `README.md` — build, test, preview, and Codex discovery notes.
- `Documentation/Checkpoint-1-Review-Disposition.md` — first independent review disposition.
- `Documentation/Local-Validation.md` and `Local-Validation-Report.md` — isolated-preview contract/evidence.
- `Documentation/Manual-Verification.md` — menu-bar/popover/Settings regression procedure.

## Herdr state

At the time of this update:

- Workspace/tab: `wJ` / `wJ:t1`.
- Prior implementation/review agents completed and exited.
- `claude-installer-fix` (Codex, GPT-5.6-sol, xhigh) completed the Claude crash fix in pane `wJ:pB` and is idle if still present.
- `claude-install-review` (Claude Code, Opus 5, high effort) completed the independent read-only review in pane `wJ:pC` and is idle if still present.
- No worker needs to be resumed unless further defects are found.

## Remaining work

User-prioritized next steps:

1. Continue hands-on testing of the normal Debug app with real local Codex and Claude snapshot data.
2. Optionally configure an OpenRouter management key through explicit user action, then verify that real integration.
3. Fix any UX/runtime defects found during hands-on testing and add regression coverage.
4. Re-run the complete test suite and normal-app manual checklist before the next release-oriented checkpoint.

Deferred until requested:

- Developer ID signing and notarization.
- Signed data-protection-Keychain entitlement validation.
- Embedded helper distribution-signature verification.
- Broad Codex version compatibility and remaining sanctioned live/browser checks from Research §6.
- Forced host-level high-contrast/reduced-motion testing.

## Running the normal app

Recommended:

1. Open `UsageTool.xcodeproj`.
2. Select scheme **UsageTool** and destination **My Mac**.
3. Press **⌘R**.
4. The app has no Dock window because it is an `LSUIElement`; use the gauge icon in the menu bar.

For Codex, leave Settings › Providers › Codex › Executable empty to use automatic discovery, or choose an explicit binary. The app displays the resolved executable and discovery origin.

## Security reminders

- Never call undocumented/private provider endpoints or scrape dashboards.
- Never read Codex or Claude credentials.
- Never mutate real `~/.claude/settings.json` in automated tests.
- Never persist or log an OpenRouter key outside Keychain.
- Never make model requests merely to refresh usage.
- Do not treat missing or elapsed data as zero/full capacity.
