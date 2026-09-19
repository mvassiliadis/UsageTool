# Manual menu-bar verification

The status items live in the system menu bar, not in a window the test host owns, so they cannot
be driven by XCTest/Swift Testing. `Tests/UsageToolTests/MenuBarSceneTests.swift` pins the
preference rules the items are built from; the checks in this file cover the parts that only a
real launch can show.

## How the items are built

`MenuBarItemsController` owns one `NSStatusItem` per visible item and opens `PopoverView` in a
transparent `MenuBarPanel`, centred under the item that was clicked, with the caret from
`PopoverChromeShape` pointing back at it. The app declares no `MenuBarExtra` scenes — only
`Settings`.

## The defect this guards against

The app previously declared four `MenuBarExtra` scenes. `MenuBarExtra(isInserted:)` observes its
controller's visibility with KVO and pushes the binding's current value back on **every**
scene-graph update, not only when the user adds or removes the item. The insertion-binding setters
mutated `@Observable` preferences unconditionally, so each write-back invalidated the scene graph,
which produced another write-back. The app spun forever in `AppGraph.graphDidChange()` →
`AppMenuBarExtrasController.updateMenuBarExtras` → the binding setter, pinned at 100% main-thread
CPU. The scene update never completed, so **no status item was ever installed and no menu-bar click
was ever delivered** — the symptom was a blank, dead menu-bar slot in an otherwise healthy, still
running `LSUIElement` process.

Visibility is now only ever *read*, by `MenuBarItemsController.sync()` under
`withObservationTracking`, so that exact cycle can no longer form. A change that writes preferences
back from inside `sync()` would recreate it. The cheapest detection is step 2 below: a healthy idle
UsageTool uses ~0% CPU.

`PopoverView` sizing is part of the same story. The panel takes its height from the hosting
controller's `preferredContentSize`, which comes from the root view's *definite* height; a root
`.frame(minHeight:)` collapses it to that minimum and clips anything taller, which is how the
onboarding state's action button was once cut off. Both branches are sized to their own content —
and `fixedSize` is deliberately **not** used on the provider list, because it sizes the scroll view
to its content and then clips it, leaving rows unreachable.

## Procedure

Build and launch the normal Debug app (not the local-validation variant):

```sh
xcodebuild \
  -project UsageTool.xcodeproj \
  -scheme UsageTool \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/UsageToolDerivedData \
  build

open -a /tmp/UsageToolDerivedData/Build/Products/Debug/UsageTool.app
```

| # | Check | Expected |
|---|---|---|
| 1 | Menu bar after launch | The `usage.gauge` template icon is drawn, tinted for the current menu-bar appearance. |
| 2 | `ps -o %cpu= -p $(pgrep -x UsageTool)` after ~5s idle | ~0.0. A pegged core means the scene-graph live-lock is back. |
| 3 | `sample $(pgrep -x UsageTool) 2` | The main thread is parked in `mach_msg_trap` under `-[NSApplication run]`, **not** in `AppGraph.graphDidChange()`. |
| 4 | Click the icon | The popover appears below the item, 340 pt wide, with the Usage header, refresh button and gear. It is **centred on the icon** and its caret points at the icon; the icon shows the pressed highlight while it is open. |
| 4a | Click the icon again, then click elsewhere on the desktop while it is open, then press Escape while it is open | Each dismisses the popover exactly once — clicking the icon of an open popover closes it and does not immediately reopen it. |
| 4b | Drag the item to the far right of the menu bar (⌘-drag) and open it | The panel stops 8 pt from the screen edge and the caret shifts off-centre to keep pointing at the icon, instead of the panel hanging off the screen. |
| 4c | Expand a provider disclosure inside the popover | The panel grows downward; its top edge and caret stay put against the menu bar. |
| 5 | Click the gear | The Settings window opens **in front** and UsageTool becomes frontmost. |
| 5a | With Settings open, activate another app (so Settings is buried), then click the icon and the gear again | Settings comes back **in front**. `onAppear` fires only on the first open, so this is the case that regresses if a call site stops going through `openSettingsWindow`. |
| 5b | Repeat 5a with **Xcode** frontmost | Settings still comes to the front. Xcode does not yield to `NSApp.activate()` — cooperative activation lets the frontmost app keep the spot — so this case depends on `orderFrontRegardless()` and regresses if only the activation call is left. |
| 6 | Dock | No Dock tile: `LSUIElement` keeps the activation policy at `.accessory` (`NSRunningApplication.activationPolicy == .accessory`). |
| 7 | Settings → Menu Bar → Icon style → *Icon and summary* | The main item becomes icon + summary; with no providers connected it reads `— · — · —` (never `0%`). |
| 8 | Settings → Menu Bar → Separate items → enable one | A second status item appears, e.g. `Codex —`. Disabling it removes that item and leaves the main one. |
| 9 | Repeat 2 after 7 and 8 | Still ~0.0% CPU: preference changes settle in one update. |
| 10 | Popover height, no providers connected | ~323 pt: the gauge symbol, headline, two-line subhead, the three provider marks, `Open Settings…` **and** the footer are all visible, with no internal scroll bar. |
| 11 | Popover height, providers connected | Sized to the provider list, growing up to `Popover.maxHeight` (560). Beyond that the list scrolls with the header and footer pinned. |
| 12 | Scroll a list taller than `maxContentHeight` | The rows scroll and the first/last rows are reachable. Synthetic `CGEvent` scroll wheels do not reach a menu-bar popover, so this one has to be done by hand. |
| 13 | Settings → Providers → Codex, with the path field empty | **Resolved** shows the discovered executable and how it was found, e.g. `…/.nvm/versions/node/v22.22.3/bin/codex` · *Found automatically · nvm*. Status is not `Codex CLI not found`. |
| 14 | Type a nonexistent path into **Executable** and press Return | **Resolved** turns to `The configured path isn’t an executable file` with that path beneath it, Status becomes `The configured Codex path isn’t executable`, and the child process is terminated (`pgrep -f 'codex app-server'` is empty). Discovery is *not* silently substituted. |
| 15 | Click **Choose…** | An open panel appears with hidden files shown, so `~/.nvm/…` is reachable. Picking a binary refreshes Codex against it immediately. |
| 16 | Click **Automatic** | The field clears, discovery runs again, and Codex reconnects to the discovered executable. |
| 17 | `ps eww -p $(pgrep -P $(pgrep -x UsageTool))` | The child has only `HOME`, `PATH`, `TMPDIR` (plus `LANG`/`LC_CTYPE`/`CODEX_HOME` when the app has them) and its `PATH` starts with the executable's own directory. No other variable is inherited. |
| 18 | Quit from the popover footer | The process exits and the status items disappear. |

Steps 7, 8 and 13–16 write to real user preferences (`dev.usagetool.app`), so restore *Icon only* and turn
the separate item back off when you are done, and leave the Codex **Executable** field empty (Automatic).
