# UsageTool — UI/UX Design Specification

**Product:** UsageTool, a native macOS menu-bar utility showing remaining personal subscription usage for OpenAI Codex and Anthropic Claude (via Claude Code), and remaining OpenRouter account credits.
**Deployment target:** **macOS 27** (minimum and primary). Build with the current Xcode and the macOS 27 SDK. SwiftUI-first; AppKit only where SwiftUI has no equivalent.
**Design language:** the current macOS design language (Liquid Glass materials, concentric corner radii, SF Pro / SF Pro Rounded, SF Symbols with symbol effects). Nothing in this spec is framed around pre-Liquid-Glass limitations. Where a compatibility note appears it is marked *Secondary* and may be ignored for the macOS 27-only build.
**Scope boundary:** For OpenAI and Anthropic, UsageTool reports **personal Codex and Claude subscription limits only** (the rate-limit windows a subscriber sees in Codex and Claude Code). It does not report organization API usage or cost, Anthropic organization Usage & Cost, token spend, or accept Admin/organization API keys, and no settings for those exist. OpenRouter is the deliberate exception: it shows **remaining USD account credits** via OpenRouter’s documented `/api/v1/credits` endpoint, authenticated with a user-created **management key**. Nothing else from OpenRouter (key limits, per-model spend, generation logs) is in scope.
**Status:** Implementation-ready, revision 2. Companion mockups: `UsageTool-Popover.svg`, `UsageTool-Settings.svg`.

---

## 0. Design principles (decisions that everything else follows)

1. **Numbers first.** The remaining quota is the largest, highest-contrast element in every provider block. Everything else (labels, source, resets) is subordinate typography.
2. **Missing is never zero.** Missing or unknown values render as an em dash `—` with an explanatory caption and an empty, dotted track. A `0%` or `$0.00` is only ever shown when the provider actually reports it.
3. **Status is never color-only.** Every warning/error state has a symbol and text. Color (bar fill, glyph tint) is reinforcement.
4. **Native panel, not a dashboard.** One glass panel, inset separators between providers, no nested cards, no gradients, no nested glass inside the panel. Personality comes from typography, rounded numerals, provider accent tints on glyph tiles and capacity bars, and considered motion.
5. **Honest provenance.** Each provider block carries a one-line source caption. Claude always reads “Last reported by Claude Code · <age>”. Codex always reads “Via local Codex app-server”. OpenRouter always reads “OpenRouter credits API”.
6. **Glanceable, then disclosable.** The default popover fits in ≈350 pt. Each provider block can expand for absolute reset times, credit totals, and diagnostics.
7. **Subscription limits, not spend.** Codex and Claude blocks show percentage-of-window remaining for a personal subscription and nothing else: no dollars, no tokens, no organization totals. Only the OpenRouter block shows money, because OpenRouter credits are a prepaid USD balance.
8. **A balance is not an allowance.** OpenRouter’s cumulative totals are never turned into a percentage or a capacity bar. The dollar balance stands alone; totals appear only as plainly labeled values in the expanded detail.

---

## 1. Information architecture

```
Menu bar
├── Main item (icon, optional summary text)            → opens the popover
└── Optional per-provider text items (0–3)             → each opens equivalent popover content beneath itself, focused to that provider
    ├── "Codex 73%"
    ├── "Claude 42%"
    └── "OpenRouter $18.20"

Popover (MenuBarExtra, .window style)
├── Header: title "Usage", Refresh, Settings
├── Provider block: Codex        (headline %, windows: 5-hour, 7-day)
├── Provider block: Claude       (headline %, windows: 5-hour, 7-day — the only windows the export provides)
├── Provider block: OpenRouter   (headline $ credits remaining; no bar, no rows)
│   └── each block: expandable detail (absolute resets; credit totals; last fetch; diagnostics)
└── Footer: freshness line, Quit

Settings window (Settings scene, toolbar tabs)
├── General     — refresh cadence, staleness threshold, headline window rule, launch at login
├── Providers   — Codex (local app-server), Claude (status-line adapter), OpenRouter (management key)
├── Menu Bar    — main item style, separate text items, warning styling, live preview
└── About       — version, privacy statement, links
```

Provider order is fixed: Codex, Claude, OpenRouter (can be reordered in Settings › Menu Bar; the popover follows the same order). Disconnected providers stay in the list as a compact “Set up” row so the layout is stable; users can hide a provider entirely in Settings › Providers.

---

## 2. Design tokens

All values in points. Implement as a `DesignTokens` enum; never hard-code in views.

### 2.1 Spacing & layout

| Token | Value | Use |
|---|---|---|
| `space.2` | 2 | caption-to-label line gap |
| `space.4` | 4 | icon button spacing, pill padding (v) |
| `space.6` | 6 | window row spacing, pill padding (h) |
| `space.8` | 8 | header→content, block header→rows |
| `space.10` | 10 | glyph tile→text, block vertical padding |
| `space.12` | 12 | popover top inset |
| `space.16` | 16 | popover horizontal inset, separator inset |
| `popover.width` | 340 | fixed |
| `popover.minHeight` | 160 | onboarding/empty state |
| `popover.maxHeight` | 560 | content scrolls beyond this |
| `settings.width` | 560 | fixed |
| `settings.minHeight` | 420 | grows with content per tab |

### 2.2 Radii

Use concentric radii: inner radius = outer radius − inset.

| Token | Value | Use |
|---|---|---|
| `radius.panel` | system | popover corner radius is owned by the system (do not override) |
| `radius.tile` | 6 | provider glyph tile (24 pt) |
| `radius.bar` | 3 | capacity bar (6 pt tall capsule) |
| `radius.pill` | capsule | status pills |
| `radius.preview` | 8 | menu-bar preview strip in Settings |

### 2.3 Typography

System font only. Numerals use `design: .rounded` and `.monospacedDigit()`. Use text styles (not fixed sizes) so Dynamic Type / “Text size” in Accessibility settings scales the UI; where a fixed size is unavoidable use `@ScaledMetric`.

| Token | SwiftUI | Size/Weight (default) | Use |
|---|---|---|---|
| `type.headline` | `.headline` | 13 / semibold | popover title, provider name, settings section titles |
| `type.body` | `.body` | 13 / regular | settings controls |
| `type.subhead` | `.subheadline` | 11 / regular | source captions, reset text |
| `type.subheadMed` | `.subheadline.weight(.medium)` | 11 / medium | window labels (“5-hour”) |
| `type.value` | `.subheadline.weight(.semibold).monospacedDigit()` | 11 / semibold | row values (73%) |
| `type.caption` | `.caption` | 10 / regular | footer freshness, headline window caption |
| `type.pill` | `.caption.weight(.semibold)` | 10 / semibold | status pills |
| `type.hero` | `.system(.title, design: .rounded).weight(.semibold).monospacedDigit()` | 26 / semibold | headline number |
| `type.menubar` | system menu bar font | 13 / medium (system) | menu-bar text items, `.monospacedDigit()` |
| `type.mono` | `.body.monospaced()` | 12 / regular | file paths, config snippets |

Line heights follow system defaults. Truncation: provider name and source caption truncate tail; numbers never truncate (minimum scale factor 0.8 on hero only).

### 2.4 Color

Semantic system colors first; provider accents are the only custom colors. All custom colors are defined in the asset catalog with Light / Dark / Light‑High‑Contrast / Dark‑High‑Contrast variants.

**System (use as-is):**
`.primary`, `.secondary`, `.tertiary` (labels); `.quaternary` (bar track); `Color(nsColor: .separatorColor)`; `.accentColor` (interactive controls only).

**Provider accents (asset catalog names):**

| Name | Light | Dark | Light HC | Dark HC | Used for |
|---|---|---|---|---|---|
| `Accent/Codex` | `#2A9DB3` | `#4CC3D9` | `#137A8E` | `#7ADCEC` | Codex tile tint, bar fill (the OpenAI mark itself is never tinted: black on light, white on dark) |
| `Accent/Claude` | `#D97757` | `#E08A5A` | `#9A4A22` | `#F0A67A` | Claude tile tint, bar fill. Light value equals the official Claude Spark “Clay”; the mark itself always renders in `#D97757` |
| `Accent/OpenRouter` | `#7624F4` | `#FCFCFE` | `#5A1BC0` | `#FFFFFF` | Tile tint uses Grape `#7624F4` at 12 %/30 %; the mark renders only in the official Grape (light) or Cloud (dark) colorway |

Tile background = accent at 14 % opacity (light) / 20 % (dark) (OpenRouter: Grape at 12 % / 30 %). The glyph is the provider’s **official mark** in one of its official colorways (§2.7); it is never tinted with the accent.

**Status (system colors):**

| State | Bar fill (percent providers) | Glyph | Glyph symbol | Text |
|---|---|---|---|---|
| Normal (≥ 25 % or ≥ $5) | provider accent | none | — | `.primary` |
| Low (10–25 % or $1–$5) | `.yellow` | `.yellow` | `exclamationmark.circle.fill` | `.primary` (never tinted) |
| Critical (< 10 % or < $1) | `.red` | `.red` | `exclamationmark.triangle.fill` | `.primary` |
| Exhausted (0 reported) | `.red` (track only, fill 0) | `.red` | `nosign` | `.primary` + pill “Exhausted” |
| Stale | accent at 40 % | `.secondary` | `clock.badge.exclamationmark` | `.secondary` |
| Credential expiring (≤ 7 d) | n/a | `.yellow` | `calendar.badge.exclamationmark` | `.primary` |
| Credential expired | n/a | `.red` | `calendar.badge.exclamationmark` | `.tertiary` `—` |
| Unknown / missing | none (dotted track) | `.tertiary` | `questionmark.circle` | `.tertiary` `—` |

OpenRouter has no bar; for it, Low/Critical/Exhausted apply only to the glyph placed beside the hero and to the menu-bar text item.

Thresholds are constants (`Thresholds.low = 0.25`, `Thresholds.critical = 0.10`, dollar equivalents `5.00` / `1.00`, credential warning `7 days`); not exposed in v1 settings.

**Increase Contrast:** when `colorSchemeContrast == .increased`, use the HC accent variants (automatic via asset catalog), raise bar track to `.tertiary`, and draw a 1 pt `.separatorColor` border on tiles and pills.

**Differentiate Without Color:** already satisfied by symbols + text; additionally, Low/Critical bar fills gain a diagonal hatch overlay (2 pt stripes at 45°, 30 % opacity).

### 2.5 Materials

- **Popover panel:** provided by `MenuBarExtra` `.window` style; the system applies the Liquid Glass popover material, shape, and shadow. Do **not** set a custom background, `glassEffect`, or `ultraThinMaterial` inside. Content sits directly on the panel.
- **Inside the panel:** no additional material layers. Grouping uses inset `Divider`s only.
- **Settings window:** standard window with `.formStyle(.grouped)`; grouped form backgrounds are system-provided.
- **Menu-bar preview strip (Settings › Menu Bar):** a 28 pt tall rounded rect using `Color(nsColor: .windowBackgroundColor)` with a 1 pt separator border; it *illustrates* the menu bar, it is not glass.
- **Glass usage rule:** `glassEffect` / `.buttonStyle(.glass)` are reserved for controls floating over content. The only place this occurs is the optional onboarding “Open Settings” CTA in the empty popover state (`.buttonStyle(.glassProminent)`). Everywhere else use `.bordered` / `.borderedProminent` / `.borderless`.

### 2.6 Iconography (SF Symbols)

| Purpose | Symbol | Rendering | Notes |
|---|---|---|---|
| Menu-bar main icon | custom `usage.gauge` (template) | monochrome, 18×18 canvas | See §3.2. Placeholder until asset exists: `gauge.with.dots.needle.67percent` |
| Codex | official OpenAI logomark (asset `Provider/OpenAI`) | original, black / white | 14 pt inside 24 pt tile — see §2.7. No SF Symbol substitute. |
| Claude | official Claude Spark (asset `Provider/ClaudeSpark`) | original, Clay `#D97757` only | idem |
| OpenRouter | official OpenRouter glyph (assets `Provider/OpenRouter-Grape`, `-Cloud`) | original colorways only | idem; 14 × 10 pt (aspect 1024:730) |
| Refresh | `arrow.clockwise` | monochrome | `.symbolEffect(.rotate)` while refreshing |
| Settings | `gearshape` | monochrome | |
| Expand/collapse | `chevron.right` | monochrome, `.tertiary` | rotates 90° when expanded |
| Low | `exclamationmark.circle.fill` | `.yellow` | |
| Critical | `exclamationmark.triangle.fill` | `.red` | |
| Exhausted | `nosign` | `.red` | |
| Stale | `clock.badge.exclamationmark` | `.secondary` | |
| Credential expiring / expired | `calendar.badge.exclamationmark` | `.yellow` / `.red` | OpenRouter management key |
| Auth error | `key.slash` | `.red` | |
| Network error | `wifi.exclamationmark` | `.secondary` | |
| Unavailable / unsupported | `minus.circle` | `.tertiary` | |
| Disconnected | `plus.circle` | `.accentColor` | “Set up” affordance |
| Loading | `ProgressView` (indeterminate, small) | — | not a symbol |
| Connected (settings) | `checkmark.circle.fill` | `.green` + text “Connected” | |
| Managed/read-only path | `doc.badge.gearshape` | `.secondary` | Claude snapshot path |
| Keychain note | `lock.fill` | `.secondary` | |
| Help | `HelpLink` | system | |

All SF Symbols use `.imageScale(.medium)` and inherit the text style of their row so they scale with Dynamic Type. Provider marks scale with the same `@ScaledMetric` as the tile.

### 2.7 Provider marks (official assets)

Provider identity uses each provider’s **official vector mark**, stored in `Design/Assets/ProviderIcons/` and documented in that folder’s `README.md` (exact source URL, retrieval date, published usage terms). Trademarks remain the property of their owners; the marks identify the data source and are never used as UsageTool’s own branding.

| Provider | Asset file(s) | Asset catalog name | Rendering | Allowed colorways | Notes |
|---|---|---|---|---|---|
| Codex | `openai-logomark.svg` | `Provider/OpenAI` | `.renderingMode(.template)` with `foregroundStyle(.primary)` is **not** used; render `.original` and swap the fill between pure black (light) and pure white (dark) | black, white | OpenAI publishes no separate Codex product mark; the OpenAI mark is used with the visible label “Codex”. Verify against openai.com/brand before shipping (§2.7 caveat below). |
| Claude | `claude-spark-clay.svg` | `Provider/ClaudeSpark` | `.renderingMode(.original)` | Clay `#D97757` only | Anthropic’s Trademark Guidelines permit no color, proportion or font changes; the same asset is used in light and dark. |
| OpenRouter | `openrouter-glyph-grape.svg`, `openrouter-glyph-cloud.svg` (also `-ink`, `-volt` available) | `Provider/OpenRouter-Grape`, `Provider/OpenRouter-Cloud` | `.renderingMode(.original)`; pick Grape on light, Cloud on dark | Grape, Volt, Ink, Cloud (as published) | OpenRouter: “don’t stretch, recolor, or remix the marks.” |

Rules that follow from the published guidance:
- **Never tint, recolor, add opacity, hatch, outline, shadow, or rotate a mark.** Status is communicated by the tile, pills, glyphs and text, never by altering the mark. Disabled/disconnected blocks keep the mark at full official color and use a neutral tile.
- **Never distort.** Use `.aspectRatio(contentMode: .fit)` in a fixed 14 × 14 pt box (OpenRouter renders 14 × 10). Minimum rendered size 12 pt.
- **Clear space.** Marks sit in a 24 pt tile with ≥ 5 pt on every side; nothing else is drawn inside the tile.
- **No template menu-bar glyphs.** Menu-bar items are monochrome template images; rendering the Claude or OpenRouter marks there would recolor them, so the “Glyph and value” text-item format is removed (§3.1). The custom `usage.gauge` icon is the only menu-bar image.
- **Accessibility does not depend on the mark.** Every mark is `accessibilityHidden(true)`; the provider name is always visible text and is the accessibility label.
- **Caveat (unresolved).** openai.com/brand could not be machine-fetched (HTTP 403) at retrieval time; the asset was taken from OpenAI-owned repositories instead. A human should confirm the current OpenAI logo terms (black/white usage, clear space, “not more prominent than your own mark”) before release. Third-party display of any of these marks to identify a service is at each provider’s discretion; none of the three sources grants a general license.

---

## 3. Menu bar

### 3.1 Variants

Configured in Settings › Menu Bar. All variants are template (monochrome) by default and adopt the menu bar’s automatic tint/contrast.

| Variant | Example | Width (approx.) |
|---|---|---|
| A. Icon only (default) | `[◔]` | 22 pt + system padding |
| B. Icon + summary | `[◔] 73% · 42% · $18` | 22 + text |
| C. Separate text items | `[◔]` `Codex 73%` `Claude 42%` `OpenRouter $18.20` | each item independent |
| D. Text items without icon | `Codex 73%` … (main item hidden) | requires ≥1 text item enabled; the main icon is hidden only if at least one text item remains |

Text item formats (per item, Settings popup):

| Format | Codex | Claude | OpenRouter |
|---|---|---|---|
| Name and value (default) | `Codex 73%` | `Claude 42%` | `OpenRouter $18.20` |
| Value only | `73%` | `42%` | `$18.20` |
| Short name | `Cdx 73%` | `Cld 42%` | `OR $18.20` |

Value rules for text items:
- Percent: integer, no decimals. Dollars: two decimals under $100, otherwise integer with `k` suffix (`$1.2k`).
- **Missing data:** `Codex —` (em dash), never `0%`. Tooltip explains why.
- **Stale:** value rendered as usual with a trailing `·` and `clock` symbol: `Claude 42% ◷`.
- **Critical:** prefix `exclamationmark.triangle` symbol: `⚠ Codex 8%`. Optional “Use color for warnings” toggle (default off) makes the item non-template and tints the symbol `.red`.
- **Loading (first load):** `Codex …` (ellipsis), replaced on first result.
- **Auth/Network/Expired credential:** `OpenRouter !` with `exclamationmark.circle`, tooltip carries the reason.
- Menu-bar text uses `.monospacedDigit()` so width does not jitter.

Tooltips (`.help`) on every item: `Codex · 73% of 5-hour window remaining · Resets in 2h 14m`; `OpenRouter · $18.20 credits remaining · Updated 2m ago`.

### 3.2 Main icon `usage.gauge` (custom SF Symbol)

- Canvas 18×18, template, single-color, weights: Regular, Medium (menu bar uses Medium).
- Geometry: an open ring gauge, 270° arc (gap at bottom, centered), stroke 1.6 pt, round caps, outer diameter 14 pt centered; a 2.6 pt filled dot at the ring center. The arc is *static* (decorative) — the icon does not encode live values; live values are the text items.
- Provide `Usage.symbolset` in the asset catalog (Symbol Components / SF Symbols app export). Until then use `gauge.with.dots.needle.67percent`.
- Interaction: clicking opens the popover; the icon shows the system “pressed” highlight (automatic with `MenuBarExtra`).

### 3.3 Behavior

- Left click any item → open popover content beneath **that** item. Click again or press Esc → close. Clicking outside closes.
- **Separate items are separate `MenuBarExtra` scenes.** Each optional text item is its own `MenuBarExtra(isInserted:)` scene with `.menuBarExtraStyle(.window)`. Each scene presents its **own** window instance of the same `PopoverView`, bound to the same shared observable store, so the content and state are equivalent wherever it is opened. Do not assume SwiftUI guarantees a single physical popover shared across scenes. Requirements:
  - Opening one item’s window dismisses any other UsageTool item window (track “presented” state in the store and dismiss via the scene’s presentation binding).
  - Expand/collapse state per provider lives in the store, so it is the same regardless of which item opened the content.
  - The window presented from a provider’s text item is **focused to that provider**: accessibility focus moves to its block and the block flashes 6 % accent for 600 ms (no motion under Reduce Motion).
- Order of separate items follows Settings › Menu Bar list order (drag to reorder). macOS may reposition items; the app does not fight the system.
- *Secondary:* if a secondary-click context menu becomes a requirement, implement the main item with `NSStatusItem` + `NSPopover`; keep the SwiftUI popover content unchanged.

---

## 4. Popover

### 4.1 Frame

- `MenuBarExtra("Usage", image: "usage.gauge") { PopoverView() }.menuBarExtraStyle(.window)`
- Width **340** fixed. Height = intrinsic, clamped to `popover.maxHeight` 560; beyond that the provider list scrolls (header and footer pinned, `scrollEdgeEffectStyle(.soft)` on both edges).
- Insets: 16 horizontal, 12 top, 10 bottom.
- The popover is not resizable and has no title bar.

### 4.2 Wireframe — default (all connected)

```
┌──────────────────────────────────────────────────────────┐ 340
│  Usage                                        ⟳    ⚙     │ header 28
│                                                          │ 8
│  ┌──┐  Codex                                    73%      │ ← hero 26pt rounded
│  │‹›│  Via local Codex app-server             5-hour     │ ← caption under hero
│  └──┘                                                    │ 8
│        5-hour  ████████████████████░░░░░░░  73%   2h 14m │ row 18
│        7-day   ███████████████░░░░░░░░░░░░  58%   Tue 9a │ row 18
│  ────────────────────────────────────────────────────────│ separator, inset 16
│  ┌──┐  Claude                                   42%      │
│  │✱ │  Last reported by Claude Code · 4m ago  5-hour     │
│  └──┘                                                    │
│        5-hour  ███████████░░░░░░░░░░░░░░░░  42%   1h 05m │
│        7-day   █████░░░░░░░░░░░░░░░░░░░░░  ⓘ18%   Tue 9a │ ← Low: yellow bar + glyph
│  ────────────────────────────────────────────────────────│
│  ┌──┐  OpenRouter                            $18.20      │ ← header-only block, no bar
│  │⑂ │  OpenRouter credits API       credits remaining    │
│  └──┘                                                    │
│                                                          │ 8
│  Updated 2m ago · Refreshes every 5 min            Quit  │ footer 20
└──────────────────────────────────────────────────────────┘
   16    24  10                                         16
```

Measured height ≈ 12 + 28 + 8 + 102 + 102 + 52 + 4 (two separators) + 8 + 20 + 10 = **346 pt** (matches the SVG mockup).

### 4.3 Header anatomy

| Element | Spec |
|---|---|
| Title | `Text("Usage")`, `type.headline`, `.primary`, leading |
| Refresh button | `Button { refreshAll() } label: { Image(systemName: "arrow.clockwise") }`, `.borderless`, 24×24 hit area, `.help("Refresh now (⌘R)")`, `.keyboardShortcut("r")`. While any provider is loading: `.symbolEffect(.rotate, isActive: isRefreshing)`; under Reduce Motion the symbol is replaced by a 12 pt `ProgressView()`. |
| Settings button | `Button { openSettingsWindow(openSettings) } label: { Image(systemName: "gearshape") }`, `.borderless`, 24×24, `.help("Settings… (⌘,)")`, `.keyboardShortcut(",")`. Opening Settings closes the popover. **Not** `SettingsLink`: it cannot activate the accessory app, so a Settings window that is already open behind another app stays behind it. Every settings entry point goes through `openSettingsWindow`, which opens, calls `NSApp.activate()` and then raises the window with `orderFrontRegardless()` — activation alone is a request the frontmost app can keep (Xcode does). |
| Spacing | buttons 4 pt apart, right-aligned, vertically centered on the 28 pt header |

### 4.4 Provider block anatomy (percent providers: Codex, Claude)

```
 x=16     x=50                                            x=324
 ┌──┐     Name (headline)                        Hero number
 │gl│     Source caption (subhead, secondary)    Window caption (caption, secondary)
 └──┘
          Label(44)  Bar(flex)                Value(40)  Reset(66)
```

| Element | Spec |
|---|---|
| Block | `VStack(alignment: .leading, spacing: 8)`, vertical padding 10, full width. Hover: background `.quaternary` at 50 % with 8 pt radius, inset −8 horizontally (row highlight, like Control Center modules). Click anywhere on the header toggles detail (§4.7). |
| Glyph tile | 24×24, `RoundedRectangle(cornerRadius: 6)` fill accent 14 %/20 % (OpenRouter Grape 12 %/30 %); inside it the provider’s official mark (§2.7) in a 14 × 14 pt fit box, centered, original colors. `accessibilityHidden(true)` (the visible name carries meaning). |
| Name | `type.headline`, `.primary`. |
| Source caption | `type.subhead`, `.secondary`, single line, tail truncation. Exact strings in §8. |
| Hero number | `type.hero`, `.primary`, trailing, `contentTransition(.numericText(countsDown:))`. Width hugs content; min 56. For Low/Critical on the headline window, the status glyph (13 pt) sits 4 pt to the left of the hero. |
| Window caption | `type.caption`, `.secondary`, trailing, directly under hero: the headline window’s name (“5-hour”, “7-day”, or “lowest · 7-day” when rule = lowest). In states that carry a status pill (§5) the pill takes this slot and the caption is omitted; the window is still identified by its row label. |
| Header row height | 32 (two lines left). Hero+caption stack vertically centered on it. |
| Window rows | one per reported window, in order (5-hour, 7-day). These are the only window kinds in v1 for both Codex and Claude; the Claude export provides exactly `rate_limits.five_hour` and `rate_limits.seven_day`. Rows are indented to x=50 (aligned with name). |
| Expand chevron | `chevron.right`, `.tertiary`, 8 pt, appended 4 pt after the window caption text under the hero (“5-hour ›”). Appears on hover, keyboard focus, and while expanded (rotated 90° to point down). The hero never moves. When a status pill replaces the window caption (§5), the chevron follows the pill. |

### 4.5 Window row anatomy

```
 Label(44, subheadMed, secondary)  Bar(6 tall capsule, flex)  Value(40, value style, trailing)  Reset(66, subhead, secondary, trailing)
 "5-hour"                          track .quaternary          "73%"                             "2h 14m"
                                   fill accent (or status)
```

| Element | Spec |
|---|---|
| Row | `HStack(spacing: 8)`, height 18, vertically centered |
| Label | fixed 44 pt, leading. Strings: `5-hour`, `7-day`. No per-model rows exist (the Claude export has no per-model quota; `model.display_name` is the session model, not a limit). Tail truncation. |
| Bar | custom `CapacityBar(fraction:state:)`, 6 pt tall, `Capsule()` track `.quaternary`, fill leading-aligned, width = fraction × track. Fill color per §2.4. Fill animates width with `.spring(duration: 0.5, bounce: 0.15)`; under Reduce Motion no animation. Unknown: track drawn as dotted stroke (1 pt, dash 2/2, `.tertiary`), no fill. |
| Status glyph | 10 pt, positioned 4 pt left of the value inside the value column (value column expands to 52 when a glyph is present). |
| Value | fixed 40 pt (52 with glyph), trailing, `type.value`, `.primary`. Percent integer. Unknown: `—` in `.tertiary`. |
| Reset | fixed 66 pt, trailing, `type.subhead`, `.secondary`. Format §8.3. Unknown: `Not reported`. Tooltip = absolute time. |
| Accessibility | Row is a single element: label “5-hour window”, value “73 percent remaining, resets in 2 hours 14 minutes”, traits `.updatesFrequently`. |

### 4.6 OpenRouter block (credits only)

The OpenRouter block is **header-only** when collapsed: 52 pt tall (10 + 32 + 10). There is no capacity bar and there are no window rows, because a prepaid balance has no window to fill.

| Element | Spec |
|---|---|
| Glyph tile / name | as §4.4 |
| Source caption | `OpenRouter credits API` (see §8.2 for warning/error variants) |
| Hero | `$18.20` = `total_credits − total_usage` from `/api/v1/credits`; two decimals under $100, `$1,204` above; `contentTransition(.numericText())`. Low/Critical glyph beside hero per §2.4. |
| Window caption | `credits remaining` (replaced by a pill in pill states) |
| Expanded detail (§4.7) | `Grid` rows, all plainly labeled values, never a fraction: `Total credited $50.00` · `Total used $31.80` · `Fetched Sep 19, 10:53 AM` · `Management key expires Oct 19, 2026` (or `Management key no expiry`) |

Never derive a percentage or a bar from `total_credits`; it is a lifetime cumulative figure, not an allowance.

### 4.7 Detail disclosure (expanded block)

Trigger: click block header, press Return/Space when focused, or `⌘↓`/`⌘↑`. Each block remembers its expanded state in the shared store (§3.3).

```
│  ┌──┐  Claude                                   42%      │
│  │✱ │  Last reported by Claude Code · 4m ago  5-hour   ⌄ │
│  └──┘                                                    │
│        5-hour  ███████████░░░░░░░░░░░░░░░░  42%   1h 05m │
│        7-day   █████░░░░░░░░░░░░░░░░░░░░░  ⓘ18%   Tue 9a │
│        ┌ detail (subhead, secondary, 2-col grid) ──────┐ │
│        │ 5-hour resets      Today 4:32 PM              │ │
│        │ 7-day resets       Tue Sep 22, 9:00 AM        │ │
│        │ Reported           Sep 19, 10:51 AM           │ │
│        │ Snapshot           …/UsageTool/claude-usage.json│ │
│        └────────────────────────────────────────────────┘ │
│  ────────────────────────────────────────────────────────│
│  ┌──┐  OpenRouter                            $18.20      │
│  │⑂ │  OpenRouter credits API     credits remaining  ⌄   │
│  └──┘                                                    │
│        Total credited      $50.00                        │
│        Total used          $31.80                        │
│        Fetched             Sep 19, 10:53 AM              │
│        Management key      Expires Oct 19, 2026          │
```

- Detail grid: `Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4)`, keys `.secondary`, values `.primary`, `type.subhead`, `.textSelection(.enabled)`. Claude’s grid never shows a plan or a model: the export carries neither a subscription plan nor per-model quotas. Codex’s grid adds a `Plan` row only if its App Server reports one.
- Expansion animates height with `.snappy` (0.25 s); chevron rotates 90°. Reduce Motion: crossfade only (`.transition(.opacity)`), no height animation beyond system default.

### 4.8 Footer

| Element | Spec |
|---|---|
| Freshness | `type.caption`, `.secondary`, leading. Text: `Updated 2m ago · Refreshes every 5 min` / `Updated 2m ago · Manual refresh` / `Refreshing…`. “Updated” = most recent successful fetch of any provider; per-provider ages live in each block’s caption or detail. Updates live (timer, 30 s granularity). |
| Quit | `Button("Quit")`, `.borderless`, `type.caption`, `.secondary`, trailing, `.keyboardShortcut("q")`. Hover: `.primary`. |

### 4.9 Empty / onboarding popover (no providers configured)

```
┌──────────────────────────────────────────────────────────┐
│  Usage                                        ⟳    ⚙     │
│                                                          │
│                     ┌──┐ ┌──┐ ┌──┐                       │ three neutral tiles with the official marks
│                     └──┘ └──┘ └──┘                       │
│              No providers connected yet                  │ headline
│    Connect Codex, Claude Code, or OpenRouter to see      │ subhead, secondary, centered, 2 lines max
│    remaining usage here.                                 │
│                                                          │
│                   [ Open Settings… ]                     │ .glassProminent (the only glass control)
│                                                          │
│  Nothing to refresh                               Quit   │
└──────────────────────────────────────────────────────────┘
```
Implemented with `ContentUnavailableView` (custom label view for the three tiles, description text, actions). Height ≈ 220. Refresh button disabled.

---

## 5. Provider block states

Every provider’s view model exposes exactly one `ProviderState`:

```swift
enum ProviderState {
    case disconnected                          // not configured
    case loading(previous: Snapshot?)          // first load (nil) or refresh (previous shown)
    case connected(Snapshot)                   // fresh; Snapshot.credential may carry an upcoming expiry
    case stale(Snapshot, age: TimeInterval)
    case partial(Snapshot, missing: [WindowID]) // percent providers only
    case unavailable(reason: UnavailableReason) // CLI not installed / not signed in / not offered for account
    case authError(message: String)            // key rejected, or key is not a management key
    case credentialExpired(expiredAt: Date, previous: Snapshot?) // OpenRouter management key past expires_at
    case networkError(previous: Snapshot?, message: String)
}
```

Rendering rules (hero / rows / caption / pill / actions). “Kept” = show last known values dimmed to `.secondary`. The pill sits in the window-caption slot directly under the hero, right-aligned to x=324 (see §4.4).

| State | Hero | Rows (percent providers) | Source caption | Pill (under hero, replaces window caption) | Action |
|---|---|---|---|---|---|
| **connected** | value | bars + values | normal | none | — |
| **connected, credential expiring (≤ 7 d)** | value | — (OpenRouter) | `OpenRouter credits API · key expires in 3d` | `📅 Expires in 3d` (`calendar.badge.exclamationmark`, `.yellow` tint) | click pill → Settings › Providers › OpenRouter |
| **loading (first)** | `—` `.tertiary`, 26 pt, with 12 pt `ProgressView` 6 pt to its left | dotted tracks, values `—`, labels shown | `Loading…` | none | — |
| **loading (refresh)** | previous value, `.primary` | previous bars | unchanged | none; header refresh icon rotates | — |
| **stale** | value `.secondary` | fills at 40 % opacity, values `.secondary` | `Last reported by Claude Code · 3h ago` (Claude) / `Via local Codex app-server · 3h ago` / `OpenRouter credits API · 3h ago` | `◷ Stale` (`clock.badge.exclamationmark`, `.secondary` tint pill) | click pill → tooltip “No update for 3h. Threshold is 30 min (Settings › General).” |
| **partial** (Claude/Codex) | value if headline window present, else `—` with caption `not reported` | present rows normal; missing rows dotted track + `—` + reset text “Not reported” | normal (no suffix: a suffix would collide with the hero at 340 pt) | none (the row-level `—` + “Not reported” is the signal) | expanded detail lists what is missing |
| **disconnected** | none (block collapses to 1 row, 28 pt) | none | `Not set up` | none | `Set up…` `.bordered` small button trailing (opens Settings › Providers, scrolled to provider) |
| **unavailable** | `—` `.tertiary` | none | reason text (§8.2) | `⊖ Unavailable` `.tertiary` | `Learn more` link (Help) |
| **authError** | `—` `.tertiary` | none | `Key rejected` / `Not a management key` | `⚿ Auth error` `.red` tint pill, `key.slash` | `Fix…` `.bordered` small → Settings › Providers |
| **credentialExpired** | `—` `.tertiary` | none | `Management key expired` | `📅 Expired` `.red` tint pill, `calendar.badge.exclamationmark` | `Fix…` `.bordered` small → Settings › Providers › OpenRouter |
| **networkError (with previous)** | previous, `.secondary` | previous bars 40 % | `Couldn’t refresh · showing 12m ago` | `⚠ Offline` `.secondary`, `wifi.exclamationmark` | `Retry` link |
| **networkError (no previous)** | `—` `.tertiary` | dotted | `Couldn’t reach OpenRouter` | `⚠ Offline` | `Retry` link |

**Pill anatomy:** capsule, `type.pill`, symbol 10 pt + 4 pt + text, padding 6 × 3, background = tint at 14 %, foreground = tint; `.tertiary` pills use `.quaternary` bg and `.secondary` fg. With Increase Contrast, add a 1 pt border of the tint.

**Never-zero rule enforcement:** `CapacityBar` takes `fraction: Double?`; `nil` draws the dotted track. Value views take `String?`; `nil` renders `—` in `.tertiary`. A snapshot with `remaining == 0` renders `0%` / `$0.00` with the Exhausted treatment (red `nosign`, pill `Exhausted`), so real zero and unknown are visually distinct.

### 5.1 State wireframes (single blocks)

Disconnected (compact, 28 pt):
```
│  ┌──┐  OpenRouter · Not set up                 [ Set up… ] │
│  └──┘                                                      │  neutral tile; mark stays at official color
```

Loading, first fetch:
```
│  ┌──┐  Codex                                 ◌  —          │  ◌ = 12pt ProgressView
│  │‹›│  Loading…                                            │
│        5-hour  · · · · · · · · · · · · · · · ·   —          │  dotted track
│        7-day   · · · · · · · · · · · · · · · ·   —          │
```

Stale (Claude, 3 h):
```
│  ┌──┐  Claude                                   42%        │  hero .secondary
│  │✱ │  Last reported by Claude Code · 3h ago  ◷ Stale      │  pill in caption slot
│  └──┘                                                      │
│        5-hour  ▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░░░  42%   —        │  fill 40%, reset elapsed → "—"
│        7-day   ▒▒▒▒░░░░░░░░░░░░░░░░░░░░░░  ⓘ18%   Tue 9a   │
```

Partial (Claude, 7-day not in the last report):
```
│  ┌──┐  Claude                                   42%        │
│  │✱ │  Last reported by Claude Code · 4m ago       5-hour   │
│  └──┘                                                      │
│        5-hour  ███████████░░░░░░░░░░░░░░░░  42%   1h 05m   │
│        7-day   · · · · · · · · · · · · · ·   —  Not reported│
```

Auth error (OpenRouter):
```
│  ┌──┐  OpenRouter                                —         │
│  │⑂ │  Not a management key                ⚿ Auth error    │  red-tint pill
│  └──┘  This key can’t read credits.                 [Fix…] │  subhead .secondary, 1 line + button
```

Expired credential (OpenRouter):
```
│  ┌──┐  OpenRouter                                —         │
│  │⑂ │  Management key expired                📅 Expired    │  red-tint pill
│  └──┘  Expired Sep 18. Create a new key.            [Fix…] │
```

Unavailable (Codex, CLI not installed):
```
│  ┌──┐  Codex                                     —         │
│  │‹›│  Codex CLI not found                 ⊖ Unavailable   │
│  └──┘  Install Codex and sign in to read usage. Learn more │
```

Network error with previous (OpenRouter, header-only block + Retry):
```
│  ┌──┐  OpenRouter                             $18.20       │  .secondary
│  │⑂ │  Couldn’t refresh · showing 12m ago     ⚠ Offline    │
│  └──┘  Retry                                               │  link-style
```

---

## 6. Provider-specific rules (compliance & scope)

What each block may show:

| Provider | In scope (v1) | Out of scope (never designed) |
|---|---|---|
| Codex | Personal subscription rate-limit windows (5-hour, 7-day) as % remaining, reset times, plan name, read from the official local Codex App Server | OpenAI organization API usage, cost, token counts, project budgets, Admin API keys |
| Claude | Personal Claude subscription windows reported by Claude Code (`rate_limits.five_hour`, `rate_limits.seven_day`) as % remaining, with reset times | Anthropic organization Usage & Cost, Admin API keys, token spend, workspace budgets, per-model quotas (not provided by the export), subscription plan name (not provided), `spend_limit` (a gateway spend limit, not subscription capacity), `model.display_name` (session model, not a quota) |
| OpenRouter | Remaining USD account credits from `/api/v1/credits` (`total_credits − total_usage`), plus the two totals as labeled values in detail | Key limits / ordinary-key allowances, per-model spend, generation logs, any percentage derived from totals |

| Provider | Allowed source | Required labeling | Never |
|---|---|---|---|
| **Codex** | The official local Codex App Server interface of the installed, signed-in Codex CLI. | Source caption always `Via local Codex app-server`. Settings explains it reads from the locally installed, signed-in Codex CLI. | No ChatGPT/OpenAI account sign-in inside UsageTool, no OpenAI API/Admin keys, no organization usage or cost, no reading Codex’s own credential files, no dashboard scraping. |
| **Claude** | A user-enabled **UsageTool status-line adapter**: Claude Code invokes the configured `statusLine` command and passes its status JSON on stdin; the adapter extracts only the rate-limit fields and atomically writes a sanitized snapshot file that UsageTool reads (§7.5). | Caption always `Last reported by Claude Code · <age>`. Settings › Providers › Claude headline: “Claude Code status-line adapter”. | No Claude consumer OAuth tokens, no session cookies, no Anthropic API/Admin keys, no organization Usage & Cost, no reading `~/.claude` credentials, no Anthropic console scraping. The UI must never present a “Sign in to Claude” or “Enter API key” control for Claude. The adapter never writes session IDs, working directories, transcript paths, cost or context fields, `model.display_name`, or `spend_limit`. No plan name and no per-model window is ever shown for Claude. |
| **OpenRouter** | `/api/v1/credits` for the balance, authenticated with a user-created **management key** stored in Keychain; `/api/v1/key` used on connect (and on each refresh, cheaply) to validate that `is_management_key == true` and to read `expires_at`. | Caption always `OpenRouter credits API`. Settings field is labeled **Management key**, with the disclosure in §7.7 shown before entry. | No ordinary API keys (they cannot read `/api/v1/credits`, and there is no balance-only scope to offer), no dashboard scraping, no importing keys from other apps’ config files, no key-limit or per-key usage display. |

Partial data applies to percent providers only (a window missing from a report). For OpenRouter, a missing `total_credits` or `total_usage` is treated as a network/parse error, not partial.

---

## 7. Settings window

### 7.1 Frame & navigation

- `Settings { SettingsView() }` scene; `TabView` with `Tab("General", systemImage: "gearshape")`, `Tab("Providers", systemImage: "point.3.connected.trianglepath.dotted")`, `Tab("Menu Bar", systemImage: "menubar.rectangle")`, `Tab("About", systemImage: "info.circle")`. Toolbar-style tabs (standard for app Settings).
- Window width 560 fixed; height fits content per tab (`.windowResizability(.contentSize)`).
- Each tab is a `Form` with `.formStyle(.grouped)`, sections with headers; controls right-aligned per the grouped form defaults.
- Opened via `⌘,`, the popover gear, `Set up…`/`Fix…` buttons (which pass a `ProviderID` to select the Providers tab and scroll/flash that section).

### 7.2 Providers tab — wireframe

```
┌────────────────────────────────────────────────────────────────────┐ 560
│  ⚙ General   ⛶ Providers   ▭ Menu Bar   ⓘ About                    │ toolbar tabs
├────────────────────────────────────────────────────────────────────┤
│  ┌──┐ Codex                                                        │ section header: tile + name
│  │‹›│ Reads the remaining subscription usage that the locally      │ description
│  └──┘ installed, signed-in Codex CLI reports through its App Server│
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Show Codex                                          [● on ]  │  │ Toggle
│  │ Status         ✓ Connected · Codex 0.9.4 · updated 2m ago    │  │ LabeledContent
│  │ Windows        5-hour 73% · 7-day 58%                        │  │
│  │                                        [ Test Connection ]   │  │
│  ╰──────────────────────────────────────────────────────────────╯  │
│                                                                    │
│  ┌──┐ Claude                                                       │
│  │✱ │ A small adapter runs as Claude Code’s status line, keeps only│
│  └──┘ the rate-limit fields, and writes them to a snapshot file.   │
│       No Claude sign-in or credentials are used.                   │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Show Claude                                         [● on ]  │  │
│  │ Adapter        ✓ Installed · composes with your status line  │  │ status of ~/.claude/settings.json statusLine
│  │ Snapshot       ⚙ …/UsageTool/claude-usage.json      [Reveal] │  │ managed, read-only path
│  │ Status         ✓ Last reported by Claude Code · 4m ago       │  │
│  │ Windows        5-hour 42% · 7-day 18%                        │  │
│  │                                     [ Configure Adapter… ]   │  │ opens sheet §7.5
│  ╰──────────────────────────────────────────────────────────────╯  │
│       Updates only while a Claude Code session is running.         │ footer
│                                                                    │
│  ┌──┐ OpenRouter                                                   │
│  │⑂ │ Shows remaining USD account credits from OpenRouter’s        │
│  └──┘ credits API. Reading credits requires a management key;      │
│       see the note before adding one.                              │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Show OpenRouter                                     [● on ]  │  │
│  │ Management key ••••••••••••••••••••••••4f2a     [ Replace… ]  │  │ SecureField (masked, last 4 shown)
│  │ Status         ✓ Connected · management key · expires Oct 19 │  │
│  │                                        [ Test Connection ]   │  │
│  ╰──────────────────────────────────────────────────────────────╯  │
│   🔒 Stored in the macOS Keychain and sent only to openrouter.ai.  │ footer
│      This key can manage your OpenRouter API keys. Revoke it any   │
│      time at openrouter.ai › Settings › Keys.                      │
└────────────────────────────────────────────────────────────────────┘
```

Section behaviors:
- **Section header** is a custom `HStack` (24 pt tile + name `type.headline`) followed by the description as the `Section` footer text (`.secondary`, `type.subhead`).
- **Show <Provider>** toggle (`.switch`) hides the block from the popover and its text item from the menu bar; setup fields remain visible.
- **Status** row uses `LabeledContent("Status") { HStack { Image(systemName:); Text } }`. Symbols and strings:
  - Connected: `checkmark.circle.fill` `.green` + `Connected · <version/age>`; OpenRouter appends `· management key · expires <date>` or `· no expiry`
  - Expiring soon: `calendar.badge.exclamationmark` `.yellow` + `Connected · management key expires in 3 days`
  - Expired: `calendar.badge.exclamationmark` `.red` + `Management key expired Sep 18. Replace it.`
  - Stale: `clock.badge.exclamationmark` `.secondary` + `Stale · last reported 3h ago`
  - Auth error: `key.slash` `.red` + `Key rejected (401). Replace the key.` / `This isn’t a management key, so it can’t read credits.`
  - Network: `wifi.exclamationmark` `.secondary` + `Couldn’t reach OpenRouter · retrying`
  - Unavailable: `minus.circle` `.tertiary` + `Codex CLI not found` / `Not supported for this account type`
  - Not set up: `circle.dotted` `.tertiary` + `Not set up`
  - Testing: `ProgressView` + `Testing…`
- **Test Connection**: `.bordered`, runs a single fetch, result replaces the Status row inline (no alerts). For OpenRouter this calls `/api/v1/key` first (requires `is_management_key`, records `expires_at`), then `/api/v1/credits`.
- **Claude › Adapter** row states: `Installed · composes with your status line` / `Installed` / `Not installed` (`circle.dotted`) / `Configured elsewhere` (statusLine points to a command that is not the adapter; footer explains Configure Adapter will chain it).
- **Claude › Snapshot** row: managed, read-only path shown with `doc.badge.gearshape`, abbreviated, `.textSelection(.enabled)`, and a `Reveal` button (`NSWorkspace.shared.activateFileViewerSelecting`). There is **no** file chooser: the adapter owns the file location. Path: `~/Library/Application Support/UsageTool/claude-usage.json`.
- **Claude › Configure Adapter…** opens the sheet in §7.5.
- **OpenRouter › Management key**: on first entry (field empty) clicking the field or `Add…` first shows the disclosure sheet (§7.7); the `SecureField` becomes editable after `Continue`. When stored, shows `••••4f2a` with `Replace…`. Paste is supported; the field validates prefix `sk-or-` and shows inline `type.subhead` `.red` “Doesn’t look like an OpenRouter key” without blocking save. On save, the key is validated via `/api/v1/key`; a non-management key is rejected with the Auth error status text above and is **not** stored.
- Order of sections = provider order.

### 7.3 Menu Bar tab — wireframe

```
┌────────────────────────────────────────────────────────────────────┐
│  ⚙ General   ⛶ Providers   ▭ Menu Bar   ⓘ About                    │
├────────────────────────────────────────────────────────────────────┤
│  Preview                                                           │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ ⋯  ◔  Codex 73%  $18.20   ᯤ  ◐  10:55 AM                     │  │ 28pt strip, live, monochrome
│  ╰──────────────────────────────────────────────────────────────╯  │
│                                                                    │
│  Main item                                                         │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Show icon                                           [● on ]  │  │
│  │ Icon style               ( Icon only  ◆ Icon and summary )   │  │ Picker .segmented
│  │ Summary                  ( 73% · 42% · $18          ⌄ )      │  │ enabled only for "Icon and summary"
│  ╰──────────────────────────────────────────────────────────────╯  │
│                                                                    │
│  Separate items                                                    │
│  Show a text item for each provider. Drag to reorder.              │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ ≡ ┌──┐ Codex          ( Name and value ⌄ )   Codex 73%  [● ] │  │ row: handle, tile, name, format, sample, toggle
│  │ ≡ ┌──┐ Claude         ( Name and value ⌄ )   Claude 42% [○ ] │  │
│  │ ≡ ┌──┐ OpenRouter     ( Value only     ⌄ )   $18.20     [● ] │  │
│  ╰──────────────────────────────────────────────────────────────╯  │
│                                                                    │
│  Warnings                                                          │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Show a warning symbol below 10%                     [● on ]  │  │
│  │ Use color for warnings                              [○ off]  │  │
│  │ Hide items while unavailable                        [○ off]  │  │ off = show "Codex —"
│  ╰──────────────────────────────────────────────────────────────╯  │
└────────────────────────────────────────────────────────────────────┘
```

- **Preview** renders the actual menu-bar label views (same SwiftUI views the `MenuBarExtra` labels use) in a `Color(nsColor: .windowBackgroundColor)` strip with a 1 pt separator border, radius 8, height 28. It includes placeholder system items (Wi‑Fi, Control Center, clock) drawn with `.tertiary` to convey context. Updates live as toggles change.
- **Icon style** `Picker` `.segmented`. **Summary** `Picker` `.menu` with formats `73% · 42% · $18` / `Lowest: Claude 18%`.
- **Separate items** `List` with `.onMove`, `.listStyle(.inset)`, rows 36 pt: drag handle `line.3.horizontal` `.tertiary`, tile, name, format `Picker` `.menu` (§3.1 formats), sample text (`type.menubar`, `.secondary`, `.monospacedDigit()`), `Toggle` `.switch` (label hidden, `accessibilityLabel("Show Codex in menu bar")`).
- Hiding the icon is only allowed when ≥1 separate item is on; otherwise the toggle is disabled with footer “At least one menu-bar item must stay visible.”

### 7.4 General tab

```
│  Refresh                                                           │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Refresh every            ( 5 minutes ⌄ )                     │  │ 1, 2, 5, 15, 30 min, Manually
│  │ Refresh when the popover opens                      [● on ]  │  │
│  │ Mark data stale after    ( 30 minutes ⌄ )                    │  │ 10, 30, 60 min, 3 h
│  ╰──────────────────────────────────────────────────────────────╯  │
│  Display                                                           │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Headline window          ( 5-hour ⌄ )                        │  │ 5-hour / 7-day / Lowest remaining
│  │ Show reset times as      ( Countdown ◆ Time )                │  │ segmented
│  ╰──────────────────────────────────────────────────────────────╯  │
│  System                                                            │
│  ╭──────────────────────────────────────────────────────────────╮  │
│  │ Open at login                                       [● on ]  │  │ SMAppService
│  │ Keyboard shortcut         [ ⌃⌥U ]                            │  │ optional, global hotkey recorder
│  ╰──────────────────────────────────────────────────────────────╯  │
```

### 7.5 “Configure Adapter” sheet (Claude Code status-line adapter)

Sheet 520 × ~440, `.presentationSizing(.fitted)`. Title: **Set up the Claude Code status-line adapter**.

How it works (as shown, `type.subhead`, `.secondary`, above the steps):
> Claude Code runs a `statusLine` command and passes it status JSON on stdin. UsageTool’s adapter keeps only the two rate-limit windows (`rate_limits.five_hour`, `rate_limits.seven_day`: remaining and reset time) and writes them to a snapshot file. Nothing else from the JSON is stored, and no Claude credentials are involved.

Detected state (one `LabeledContent` row, `type.body`):
- `No status line configured` → the adapter will be installed and will print a compact usage line in Claude Code.
- `Existing status line: <command>` → the adapter will **chain** the existing command: it forwards the same stdin to it and displays its output unchanged. The existing command is never removed.
- `Adapter already installed` → offers Reinstall / Remove.

Two ways to install (segmented control: **Guided** ◆ **Manual**):

**Guided** (default):
1. `Install Adapter` (`.borderedProminent`) copies the bundled helper to `~/Library/Application Support/UsageTool/bin/usagetool-statusline`, backs up `~/.claude/settings.json` to `settings.json.usagetool-backup-<date>`, and merges (never replaces) the `statusLine` key:
   ```json
   "statusLine": {
     "type": "command",
     "command": "~/Library/Application Support/UsageTool/bin/usagetool-statusline --chain '<existing command, if any>'"
   }
   ```
   If the existing value is not a `command` type or cannot be parsed, the sheet stops and switches to **Manual** with the snippet, rather than overwriting.
2. Result row: `✓ Installed · Claude Code will start reporting after its next API response`.

**Manual**: shows the exact snippet above in a `type.mono` selectable block with a `Copy` button and one line: “Add this to `~/.claude/settings.json`. Keep your existing command inside `--chain` to preserve your status line.”

Snapshot behavior (shown as three footnote lines with symbols):
- `doc.badge.gearshape` Snapshot path: `~/Library/Application Support/UsageTool/claude-usage.json` (managed by the adapter; written atomically via temp file + rename).
- `clock` Data appears only after Claude Code’s first API response in a session and updates only while a Claude Code session is running. Between sessions the last report is shown and ages into Stale.
- `lock.fill` The adapter never reads or writes Claude credentials and never stores session IDs, working directories, transcript paths, cost or context data.

Buttons: `Done` (default), `Remove Adapter` (destructive, only when installed; restores the chained command or removes the key, using the backup), `HelpLink`.

Adapter output contract (for the implementation agent): `{ "schema": 1, "reportedAt": ISO8601, "windows": [ { "id": "5h" | "7d", "remainingFraction": 0…1, "resetsAt": ISO8601? } ] }`. `5h` maps from `rate_limits.five_hour`, `7d` from `rate_limits.seven_day`; these are the only window IDs. There is no plan field, because the documented export has none. If a window is absent in Claude Code’s JSON it is omitted (→ `partial`), never written as 0. The adapter must parse tolerantly and drop `spend_limit`, `model.display_name`, and every other key; `spend_limit` is a gateway spend limit, not personal subscription capacity, and must never be surfaced.

### 7.6 About tab

App icon (64), name + version, one-paragraph privacy statement (“UsageTool talks only to openrouter.ai and the local Codex App Server, and reads the snapshot written by its own Claude Code status-line adapter.”), `Check for Updates…` (if applicable), links: Website, Privacy, Acknowledgements.

### 7.7 “Before you add a management key” sheet (OpenRouter)

Sheet 480 × ~300, `.presentationSizing(.fitted)`, shown the first time the user starts entering an OpenRouter key (and from a `?` `HelpLink` beside the field afterwards). Tone: concise, factual, native; no warning icon in the title.

Title: **About OpenRouter management keys**

Body (`type.body`, three short paragraphs):
1. OpenRouter’s credits endpoint (`/api/v1/credits`) only accepts a **management key**. OpenRouter doesn’t document a narrower, balance-only scope, so UsageTool can’t ask for less.
2. A management key can create, edit and revoke your account’s API keys, although it can’t make completion requests. UsageTool uses it for exactly one thing: reading your credit balance.
3. Create the key with an expiry date. UsageTool stores it in the macOS Keychain, sends it only to openrouter.ai, and will remind you a week before it expires. You can revoke it any time at openrouter.ai › Settings › Keys.

Buttons: `Continue` (`.borderedProminent`, default) → enables the field; `Cancel`; `Open OpenRouter Keys…` (`Link`, secondary).

---

## 8. Copy catalog

### 8.1 Fixed strings

| Key | String |
|---|---|
| popover.title | Usage |
| popover.refresh.help | Refresh now (⌘R) |
| popover.settings.help | Settings… (⌘,) |
| popover.quit | Quit |
| footer.updated | Updated %@ · Refreshes every %@ |
| footer.updated.manual | Updated %@ · Manual refresh |
| footer.refreshing | Refreshing… |
| footer.empty | Nothing to refresh |
| empty.title | No providers connected yet |
| empty.body | Connect Codex, Claude Code, or OpenRouter to see remaining usage here. |
| empty.cta | Open Settings… |
| window.5h | 5-hour |
| window.7d | 7-day |
| hero.caption.lowest | lowest · %@ |
| hero.caption.credits | credits remaining |
| detail.totalCredited | Total credited |
| detail.totalUsed | Total used |
| detail.fetched | Fetched |
| detail.managementKey | Management key |
| detail.expires | Expires %@ |
| detail.noExpiry | No expiry |
| row.notReported | Not reported |
| pill.stale | Stale |
| pill.auth | Auth error |
| pill.offline | Offline |
| pill.unavailable | Unavailable |
| pill.exhausted | Exhausted |
| pill.expiresIn | Expires in %@ |
| pill.expired | Expired |
| action.setup | Set up… |
| action.fix | Fix… |
| action.retry | Retry |
| action.learnMore | Learn more |
| action.test | Test Connection |
| action.reveal | Reveal |
| action.configureAdapter | Configure Adapter… |
| action.installAdapter | Install Adapter |
| action.removeAdapter | Remove Adapter |
| action.replaceKey | Replace… |
| action.openKeys | Open OpenRouter Keys… |
| settings.claude.footer | Updates only while a Claude Code session is running. |
| settings.openrouter.footer | Stored in the macOS Keychain and sent only to openrouter.ai. This key can manage your OpenRouter API keys. Revoke it any time at openrouter.ai › Settings › Keys. |

### 8.2 Source captions & reasons

| Situation | Caption |
|---|---|
| Codex normal | Via local Codex app-server |
| Codex stale | Via local Codex app-server · %@ ago |
| Codex CLI missing | Codex CLI not found |
| Codex not signed in | Codex isn’t signed in |
| Codex unsupported account | Usage isn’t reported for this account type |
| Claude normal / stale | Last reported by Claude Code · %@ ago |
| Claude adapter not installed | Adapter not installed |
| Claude no report yet | Waiting for Claude Code to report |
| Claude snapshot unreadable | Snapshot couldn’t be read |
| OpenRouter normal | OpenRouter credits API |
| OpenRouter stale | OpenRouter credits API · %@ ago |
| OpenRouter key expiring | OpenRouter credits API · key expires in %@ |
| OpenRouter key expired | Management key expired |
| OpenRouter 401 | Key rejected |
| OpenRouter non-management key | Not a management key |
| OpenRouter network | Couldn’t reach OpenRouter |
| Generic network w/ previous | Couldn’t refresh · showing %@ ago |
| Loading | Loading… |
| Disconnected | Not set up |

### 8.3 Number & time formats

- Percent: `Int(round(fraction × 100))%`, never `%.1f`. Values ≥ 100 show `100%`.
- Currency: `NumberFormatter` currency, USD, 2 decimals below 100, 0 decimals ≥ 100, `k` above 10,000 (`$12.4k`). Locale-aware separators.
- Age (`%@ ago`): `<60 s` → `just now`; `<60 m` → `4m`; `<24 h` → `3h`; else `2d`. Use `RelativeDateTimeFormatter` with `.abbreviated` units.
- Reset (countdown mode): `2h 14m` (< 24 h), `1d 3h` (< 7 d); elapsed/unknown → `—`. Tooltip: absolute `Date.FormatStyle(date: .abbreviated, time: .shortened)`.
- Reset (time mode): same day → `4:32 PM`; within 7 days → `Tue 9:00 AM`; else `Sep 22`.
- Key expiry: `expires in 3d` (< 7 d) / `expires Oct 19` (same year) / `expires Oct 19, 2027`.
- Accessibility value spells units in full via `Measurement`/`DateComponentsFormatter` `.full`.

---

## 9. Interactions & motion

| Interaction | Behavior |
|---|---|
| Open popover | System `MenuBarExtra` presentation; content appears with system animation. On open: if “Refresh when the popover opens” is on and last fetch > 30 s ago, trigger refresh (header icon rotates; values update in place with `numericText`). |
| Value change | `contentTransition(.numericText(countsDown: newValue < oldValue))`, 0.35 s; bars spring to new width. |
| Hover block | background `.quaternary` 50 %, radius 8, fade 120 ms; chevron appears. |
| Click block header | expand/collapse detail, `.snappy(duration: 0.25)`. |
| Hover reset text | tooltip with absolute time after 0.5 s (system `.help`). |
| Refresh | `⌘R` or header button; icon `.symbolEffect(.rotate)` while any provider is loading; footer says `Refreshing…`. |
| Retry (network error) | same as refresh for that provider only. |
| Set up / Fix | closes popover, opens Settings › Providers, scrolls to section, flashes section background (accent 10 %, 600 ms fade). |
| Quit | `⌘Q` / footer button; terminates immediately (no confirmation). |
| Low → Critical transition | glyph appears with `.transition(.symbolEffect(.appear))`; one `.symbolEffect(.bounce)` on first appearance per session; none under Reduce Motion. |
| Stale → fresh | pill disappears with `.transition(.opacity.combined(with: .scale(0.9)))`. |
| Key expiring → expired | pill tint crossfades yellow → red; block content collapses to the error layout with `.snappy`. |
| Text item clicked | that item’s window opens with the provider’s block highlighted 600 ms (accent 6 %) and accessibility focus moved to that block. |

**Reduce Motion (`accessibilityReduceMotion`):** all custom animations become `.none` or opacity crossfades ≤ 150 ms; symbol effects disabled; refresh indicator becomes a static `ProgressView`; expand/collapse uses system default height change without spring.

---

## 10. Keyboard & focus

Popover is fully keyboard operable:

| Key | Action |
|---|---|
| `Tab` / `⇧Tab` | move focus: Refresh → Settings → Codex block → (its buttons) → Claude block → … → Quit |
| `↑` / `↓` | move focus between provider blocks (`.focusSection()` per block) |
| `Return` / `Space` | toggle detail on focused block; activate focused button |
| `⌘R` | refresh all |
| `⌘,` | Settings |
| `⌘Q` | Quit |
| `Esc` | close popover |

Focus ring: system default (`.focusable()` on the block with `.focusEffectDisabled(false)`). Blocks are `.focusable(true, interactions: .activate)`.

Settings: standard form navigation; `⌘1–4` switch tabs; `Esc` closes sheets.

---

## 11. Accessibility

- **VoiceOver:** provider marks are decorative (`accessibilityHidden(true)`); the visible provider name is the label. Each provider block is an `.accessibilityElement(children: .contain)` with label `Codex`, value `73 percent of 5-hour window remaining. 7-day: 58 percent. Via local Codex app-server. Updated 2 minutes ago.`, hint `Press Return for details`. OpenRouter: `OpenRouter, 18 dollars 20 cents of credits remaining. Updated 2 minutes ago.` Rows are individually navigable inside the container. Status pills are announced as part of the value (`Stale, last reported 3 hours ago`; `Management key expires in 3 days`). Hero numbers use `.accessibilityLabel` with spelled units; decorative tiles are hidden. Menu-bar items expose label `Codex, 73 percent remaining`.
- **Live updates:** blocks use `.accessibilityAddTraits(.updatesFrequently)`; refresh completion posts an `AccessibilityNotification.Announcement("Usage updated")` only when triggered manually.
- **Dynamic Type / Text size:** all type via text styles; widths for label/value/reset columns are `@ScaledMetric`. At the largest sizes the window row wraps into two lines (label + bar on line 1, value + reset on line 2). Popover width stays 340; height grows to max then scrolls.
- **Increase Contrast:** HC color variants; bar track `.tertiary`; 1 pt borders on tiles and pills; separators use `.separatorColor` at full opacity.
- **Differentiate Without Color:** symbols + text already present; Low/Critical fills add hatch overlay (§2.4).
- **Reduce Transparency:** handled by the system material.
- **Pointer / hit targets:** all buttons ≥ 24×24 pt with `.contentShape(Rectangle())`; block header is a 32 pt-tall target.
- **Localization:** all strings in a String Catalog; layouts use leading/trailing; numbers via formatters; RTL mirrors columns (bar fill anchors leading).

---

## 12. Light & dark appearance

- Panel material, labels, separators, and tracks are all system semantic colors → automatic.
- Provider accents have explicit dark variants (§2.4) tuned for contrast on the dark glass (lighter, slightly desaturated).
- Tile tint opacity: 14 % light / 20 % dark.
- Bar track: `.quaternary` in both (renders ~8 % black / ~12 % white).
- Menu-bar items are template images and text → the system handles light/dark wallpapers and the menu-bar tint. Only the optional “Use color for warnings” makes an item non-template.
- Do not ship separate light/dark assets for symbols; only the accent color set has variants.

---

## 13. SwiftUI / AppKit mapping

| Design element | Implementation |
|---|---|
| App entry | `@main App` with `MenuBarExtra` scenes + `Settings` scene; `LSUIElement = YES` |
| Main menu-bar item | `MenuBarExtra { PopoverView() } label: { Image("usage.gauge") [+ Text(summary)] }.menuBarExtraStyle(.window)` |
| Separate text items | one `MenuBarExtra(isInserted: $prefs.showCodexItem) { PopoverView(focus: .codex) } label: { Text("Codex 73%").monospacedDigit() }` per provider. Each scene presents its own window of the same view over the shared store (§3.3); the store dismisses any other open UsageTool window when one opens. |
| Shared state | one `@Observable` `UsageStore` injected via `.environment(store)` into every scene: snapshots, provider states, expanded flags, presented-item flag |
| Popover layout | `VStack` → header `HStack`, `ScrollView` (only when needed) of `ProviderBlockView`s separated by `Divider().padding(.horizontal, 16)`, footer `HStack` |
| Header buttons | `Button` `.buttonStyle(.borderless)` (refresh, and settings via `openSettingsWindow`) |
| Provider tile | `ZStack { RoundedRectangle(cornerRadius: 6).fill(accent.opacity(…)); Image("Provider/ClaudeSpark").renderingMode(.original).resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14) }` — assets from `Design/Assets/ProviderIcons` imported into the asset catalog as vector (“Preserve Vector Data”), never `Image(systemName:)` for provider identity |
| Hero number | `Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit().contentTransition(.numericText(countsDown:))` |
| Capacity bar | custom `CapacityBar: View` (Capsule track/fill; dotted `StrokeStyle(dash:)` when nil). *Alternative:* `Gauge(value:).gaugeStyle(.accessoryLinearCapacity).tint(accent)` — rejected because it cannot draw the “unknown” dotted track. Not used for OpenRouter. |
| Status pill | `Label(text, systemImage:).labelStyle(.titleAndIcon).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(tint.opacity(0.14), in: Capsule())` |
| Detail disclosure | state-driven `if isExpanded { DetailGrid() }` with `.animation(.snappy)`; not `DisclosureGroup` (needs custom header). |
| Detail grid | `Grid` + `GridRow`, `.textSelection(.enabled)` |
| Hover highlight | `.onHover` → `RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))` background |
| Focus | `.focusable()`, `.focusSection()`, `.onKeyPress(.return)`, `.onKeyPress(.space)` |
| Empty state | `ContentUnavailableView { Label } description: { Text } actions: { Button.buttonStyle(.glassProminent) }` |
| Refresh spinner | `.symbolEffect(.rotate, isActive:)` / `ProgressView().controlSize(.small)` under Reduce Motion |
| Tooltips | `.help(_:)` |
| Settings tabs | `TabView { Tab("General", systemImage:) { … } … }` |
| Forms | `Form { Section { … } header: { … } footer: { … } }.formStyle(.grouped)` |
| Status rows | `LabeledContent` |
| Toggles | `Toggle(…).toggleStyle(.switch)` |
| Pickers | `Picker` `.pickerStyle(.segmented)` / `.menu` |
| Management key | `SecureField` + Keychain (`Security` framework, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); display `••••` + last 4; validation via `GET /api/v1/key` (`is_management_key`, `expires_at`) before storing |
| Credits fetch | `GET /api/v1/credits` → `total_credits`, `total_usage`; remaining = difference |
| Snapshot path row | `LabeledContent` + `Text(path).monospaced().textSelection(.enabled)` + `Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }` |
| Adapter install | bundled helper copied from `Bundle.main` (Contents/Helpers) to Application Support; `~/.claude/settings.json` read → JSON merge of `statusLine` only → backup → atomic write (`Data.write(options: .atomic)`) |
| Snapshot read | `FileManager` + `DispatchSource.makeFileSystemObjectSource` (or `NSFilePresenter`) to update live while Claude Code writes |
| Reorderable list | `List { ForEach(…) }.onMove` |
| Launch at login | `SMAppService.mainApp` |
| Help links | `HelpLink`, `Link` |
| Sheets | `.sheet` + `.presentationSizing(.fitted)` (§7.5, §7.7) |
| Scroll edges | `.scrollEdgeEffectStyle(.soft, for: .vertical)` on the popover scroll view |
| Timers | `TimelineView(.periodic(from:by: 30))` for relative ages and expiry countdowns |
| Reduce Motion / contrast | `@Environment(\.accessibilityReduceMotion)`, `\.colorSchemeContrast`, `\.accessibilityDifferentiateWithoutColor` |
| *Secondary (only if a context menu is required):* | `NSStatusItem` + `NSPopover(contentViewController: NSHostingController(PopoverView()))`, `behavior = .transient` |

---

## 14. Data contract expected by the UI

```swift
struct Snapshot {
    let fetchedAt: Date                 // when UsageTool obtained it
    let reportedAt: Date?               // when the source produced it (Claude adapter timestamp)
    let windows: [UsageWindow]          // percent providers; may be empty for partial
    let credits: CreditBalance?         // OpenRouter only
    let credential: CredentialInfo?     // OpenRouter only
    let plan: String?                   // Codex only, if its App Server reports one; Claude is ALWAYS nil (the export has no plan field)
    let sourceLabel: String             // §8.2 caption (localized key)
}
struct UsageWindow: Identifiable {
    let id: WindowID                    // .fiveHour, .sevenDay — no other cases in v1
    let remainingFraction: Double?      // nil = not reported → dotted track + "—"
    let resetsAt: Date?
}
struct CreditBalance {                  // from GET /api/v1/credits
    let totalCredits: Decimal           // lifetime credited (label "Total credited")
    let totalUsage: Decimal             // lifetime used (label "Total used")
    var remaining: Decimal { totalCredits - totalUsage }   // the hero; never shown as a fraction
}
struct CredentialInfo {                 // from GET /api/v1/key on connect and refresh
    let isManagementKey: Bool           // must be true; otherwise .authError("Not a management key")
    let expiresAt: Date?                // nil = no expiry; ≤ 7 d → expiring pill; past → .credentialExpired
    let label: String?                  // key name as shown on OpenRouter, for the detail grid
}
```

Headline selection (percent providers): `Prefs.headlineRule ∈ {.fiveHour, .sevenDay, .lowest}`; if the chosen window is `nil`, fall back to the next available window and set the hero caption accordingly; if none, hero `—` with caption `not reported`.

---

## 15. Non-goals & open items

- No charts/history in v1 (sparklines are a candidate for the expanded detail later; keep `Snapshot` history for it).
- No notifications in v1; the Critical state and the key-expiry pill are the only alerting surfaces. A “Notify when below 10 %” toggle is a natural General-tab addition.
- No per-provider refresh cadence; one global cadence.
- Thresholds (25 % / 10 %, 7-day expiry warning) fixed in v1.
- Menu-bar summary format is limited to the two presets listed.
- **Out of scope by product decision:** OpenAI organization API usage/cost, Anthropic organization Usage & Cost, Admin API key entry, token-spend reporting, and any settings for them. Do not add “API key” fields to the Codex or Claude provider sections; the only key field in the app is OpenRouter’s management key.
- **OpenRouter v1 is credits-only:** no key limits, no per-key usage, no percentage of totals, no ordinary-key mode.
