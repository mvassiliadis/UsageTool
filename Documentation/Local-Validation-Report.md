# Local validation report

Validated on macOS 27.0 (26A428) with Xcode 27 and the macOS 27 SDK. Developer ID signing, notarization, embedded-helper distribution-signature verification, and signed-Keychain entitlement validation were explicitly deferred.

## Build and tests

- Clean hardened Debug build: passed.
- Clean hardened Release build: passed.
- Complete deterministic suite: 37/37 passed, zero skipped, zero runtime warnings.
- Three consecutive repetitions: 111/111 executions passed.
- XCTest used `ENABLE_HARDENED_RUNTIME=NO` only for its ad-hoc host/bundle loading. App target build settings remain `ENABLE_HARDENED_RUNTIME=YES`.
- `CFFIXED_USER_HOME` was redirected to `/tmp/usagetool-test-cfhome`. The XCTest bootstrap also uses in-memory settings/secrets, temporary paths, no status item, and disabled provider operations.
- Real UsageTool preferences, UsageTool Application Support, and `~/.claude/settings.json` timestamps remained unchanged during the final isolated and repeated runs. The Claude settings SHA-256 also remained unchanged.

## Native UI smoke testing

Computer Use inspected the actual SwiftUI accessibility hierarchy and rendered screenshots for:

- populated Codex, partial Claude, and OpenRouter credit states;
- stale, unavailable, credential-expired, and empty/onboarding states;
- expanded provider detail content;
- General, Providers, Menu Bar, and About settings tabs;
- the Claude adapter setup sheet;
- light and preview-forced dark appearances;
- accessibility names, values, details, help text, disabled controls, and keyboard task switching.

The first ad-hoc custom-window approach could beachball and did not participate correctly in Command-Tab. It was removed. The final preview is a compile-time-only normal `WindowGroup`, uses `LSUIElement=NO`, contains no `MenuBarExtra` scenes, and remained responsive across repeated accessibility reads and interactions.

High-contrast and reduced-motion behavior was not forced by changing the host user’s system accessibility preferences. The implementation uses semantic colors, an increased-contrast track branch, and `accessibilityReduceMotion`; these were covered by code review rather than unsafe host-setting mutation.

## Runtime isolation and lifecycle

The final preview binary is `/tmp/UsageToolLocalPreviewDerivedData/Build/Products/Debug/UsageTool.app` with bundle identifier `dev.usagetool.localvalidation`.

While the popover and Claude setup sheet were open, process inspection found:

- no network sockets;
- no child Codex or helper process;
- no open real UsageTool preferences/Application Support or `~/.claude` path;
- no constructed production Keychain store in the validation dependency branch;
- no process remaining after termination.

Refresh and provider test/disconnect operations are disabled in the preview UI and fail closed at the shared-store boundary. OpenRouter key entry/add/save is also disabled and retains the store-level connect guard. Claude install/remove is disabled and independently constrained to a dedicated home beneath the temporary validation support root, even when the app is opened from Finder. The preview stores settings and OpenRouter material only in memory.

Four crash reports at 14:20–14:21 came from obsolete direct-launch attempts before the dedicated preview scene was introduced. Their main-thread stacks abort in AppKit application registration before UsageTool provider code. No later preview launch produced a crash report, and the final process repeatedly launched, switched focus, interacted, and terminated cleanly.

Xcode emits host-tooling diagnostics because the installed CoreSimulator/CoreDevice components do not match Xcode 27. These do not affect native macOS builds or tests; both configurations and all deterministic tests completed successfully.

## Not tested locally

- Live Codex, Claude, or OpenRouter accounts, credentials, endpoints, and compatibility probes.
- Real Codex/Claude provider configuration mutation.
- A real OpenRouter management key or production Keychain entry.
- Developer ID signing, notarization, signed helper verification, or signed data-protection-Keychain entitlement behavior.
- Changing the host user’s high-contrast or reduced-motion settings.

These are the only remaining external/release checks; they are not blockers for the unsigned local Debug validation requested here.
