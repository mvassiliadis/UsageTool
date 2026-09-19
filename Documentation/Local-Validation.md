# Isolated local validation

UsageTool has a compile-time Debug-only validation variant for safe UI and accessibility inspection without live provider accounts. It is not a shipping configuration.

## Build

```sh
xcodebuild \
  -project UsageTool.xcodeproj \
  -scheme UsageTool \
  -configuration Debug \
  -derivedDataPath /tmp/UsageToolLocalPreviewDerivedData \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG USAGETOOL_LOCAL_VALIDATION_BUILD' \
  PRODUCT_BUNDLE_IDENTIFIER=dev.usagetool.localvalidation \
  INFOPLIST_KEY_LSUIElement=NO \
  build
```

The app is produced at:

`/tmp/UsageToolLocalPreviewDerivedData/Build/Products/Debug/UsageTool.app`

## Launch

```sh
mkdir -p /tmp/usagetool-local-validation/home /tmp/usagetool-local-validation/support

env -i \
  HOME=/tmp/usagetool-local-validation/home \
  CFFIXED_USER_HOME=/tmp/usagetool-local-validation/home \
  TMPDIR=/tmp/usagetool-local-validation \
  PATH=/usr/bin:/bin \
  LANG=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8 \
  USAGETOOL_LOCAL_VALIDATION=1 \
  USAGETOOL_VALIDATION_SCENARIO=populated \
  USAGETOOL_VALIDATION_WINDOW=popover \
  USAGETOOL_VALIDATION_SUPPORT_PATH=/tmp/usagetool-local-validation/support \
  /tmp/UsageToolLocalPreviewDerivedData/Build/Products/Debug/UsageTool.app/Contents/MacOS/UsageTool
```

Scenarios are `populated`, `errors`, and `empty`. Set `USAGETOOL_VALIDATION_WINDOW=settings` for the settings window and `USAGETOOL_VALIDATION_APPEARANCE=dark` for a preview-only dark-color-scheme override.

## Isolation contract

- The validation binary always uses an in-memory `AppSettings` store and disables launch-at-login integration, including when opened without environment variables.
- OpenRouter uses `MemorySecretStore`; `KeychainStore` is not constructed.
- Provider refresh/connect/disconnect operations are disabled at the shared-store boundary. No Codex process or OpenRouter request can be started by preview controls.
- Network/power monitors, initial refresh, cadence refresh, and the Claude snapshot watcher are disabled.
- The Claude adapter sheet receives a dedicated `home` directory beneath the temporary validation support root, never ambient `HOME` or `FileManager.homeDirectoryForCurrentUser`. Install/remove controls are disabled in the preview.
- OpenRouter key entry/add/save controls are disabled in the preview, in addition to the store-level provider-operation guard.
- The compile-time validation scene contains no `MenuBarExtra`; its separate bundle identifier and `LSUIElement=NO` make it a normal focusable test window without changing menu-bar placement preferences.

Local smoke validation covered populated, partial, stale, unavailable, expired, and empty states; provider disclosures; all four settings tabs; the Claude setup sheet; keyboard task switching; light and dark rendering; accessibility names/values/help; process cleanup; and the absence of sockets, provider children, or real configuration paths in open-file inspection.

Increased-contrast and reduced-motion behavior was reviewed at the SwiftUI implementation level but not forced through system settings, because changing the host user’s accessibility preferences was outside the safe validation boundary. Live provider behavior and signed-Keychain behavior remain release-time checks.
