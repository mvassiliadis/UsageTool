# UsageTool

UsageTool is a native SwiftUI-first macOS menu-bar app for viewing Codex subscription windows, Claude Code’s sanitized status-line snapshot, and an OpenRouter account-credit balance.

## Requirements

- macOS 27
- Xcode 27 with the macOS 27 SDK
- Swift 6.4 toolchain

The app is an `LSUIElement`, uses Hardened Runtime, has no App Sandbox entitlement, and has no third-party dependencies.

## Build

```sh
xcodebuild \
  -project UsageTool.xcodeproj \
  -scheme UsageTool \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/UsageToolDerivedData \
  build
```

## Test

```sh
mkdir -p /tmp/usagetool-test-cfhome

CFFIXED_USER_HOME=/tmp/usagetool-test-cfhome \
xcodebuild \
  -project UsageTool.xcodeproj \
  -scheme UsageTool \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/UsageToolDerivedData \
  ENABLE_HARDENED_RUNTIME=NO \
  test
```

Tests use temporary home/support directories, fake local child processes, in-memory secret storage, and mocked `URLProtocol` responses. They do not make live provider calls, read real credentials, or mutate real Claude/Codex configuration.

`ENABLE_HARDENED_RUNTIME=NO` applies only to the ad-hoc XCTest host so macOS can load its ad-hoc test bundle. The project keeps Hardened Runtime enabled for the Debug and Release app products.

Create `/tmp/usagetool-test-cfhome` first. Redirecting only `CFFIXED_USER_HOME` keeps Xcode’s signing environment intact while routing Core Foundation preferences away from the host user. The app also detects XCTest before constructing production settings, Keychain, provider, watcher, or monitor dependencies.

## Codex executable discovery

A GUI-launched app inherits `launchd`'s `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), not a login
shell's, so a `codex` installed by npm/nvm, Homebrew, Volta, bun or asdf is invisible to a plain
`PATH` lookup. UsageTool therefore searches `PATH`, the standard install prefixes, and the common
Node version managers (newest runtime first), and Settings › Providers › Codex shows the resolved
path and how it was found. Leaving the **Executable** field empty means automatic discovery; a path
entered there is used verbatim and is reported as broken rather than quietly replaced.

An npm-installed `codex` is a `#!/usr/bin/env node` launcher, so finding it is not sufficient: the
child's `PATH` is composed from the executable's own directory (and its symlink target's, plus
wherever the shebang's interpreter actually lives) followed by the inherited and system entries.
The rest of the environment stays an explicit allow-list — `HOME`, `PATH`, `TMPDIR`, `LANG`,
`LC_CTYPE`, `CODEX_HOME` — and nothing else is inherited.

## Safe local preview

The compile-time local-validation variant has a separate bundle identifier, a normal focusable `WindowGroup`, no menu-bar scenes, in-memory settings/secrets, a temporary Claude home/support path, seeded fixtures, and provider operations disabled at the store boundary. Build and launch it with the commands in [Local-Validation.md](Documentation/Local-Validation.md).

## Release checks

- Build and run with the intended Developer ID signing identity; verify data-protection Keychain add/read/delete and specifically rule out `errSecMissingEntitlement` (`-34018`).
- Notarize and verify the embedded `Contents/Helpers/usagetool-statusline` signature and Hardened Runtime.
- Complete the sanctioned live compatibility probes listed as Research Q1, Q2, Q4, and Q5. Do not add fallback links until they are independently verified.

See [Checkpoint-1-Review-Disposition.md](Documentation/Checkpoint-1-Review-Disposition.md) for the complete Opus review remediation record.
See [Local-Validation-Report.md](Documentation/Local-Validation-Report.md) for the unsigned Debug build/test/UI/runtime evidence and deferred release checks.
See [Manual-Verification.md](Documentation/Manual-Verification.md) for the menu-bar/popover/Settings checks that automated tests cannot cover.
