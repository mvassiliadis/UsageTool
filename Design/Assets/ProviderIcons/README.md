# Provider icons — official marks, sources, and usage terms

These files are the **official vector marks** of the three providers UsageTool reports on. They identify the data source in the UI (next to the always-visible provider name) and are never used as UsageTool’s own branding.

**Trademark ownership remains with each provider.** “OpenAI” and the OpenAI logomark are trademarks of OpenAI. “Claude”, “Claude Code”, the Claude Spark and the Anthropic name are trademarks of Anthropic, PBC. “OpenRouter” and the OpenRouter mark are trademarks of OpenRouter, Inc. Nothing in this folder grants a license beyond what each provider publishes; the notes below record what the sources say and do not claim more.

All files were retrieved on **2026-09-19**, validated with `xmllint`, and scanned for scripts, event handlers, `foreignObject`, external references, `<image>`/base64 payloads, `<style>`, `<defs>` and comments. Each file contains exactly one `<svg>` root and one `<path>`; nothing was traced, redrawn or recolored. The bytes are identical to the source files (SHA-256 listed).

| File | Provider / asset | Source (first-party) | Retrieved | SHA-256 |
|---|---|---|---|---|
| `openai-logomark.svg` | OpenAI logomark (used to identify **Codex**) | `https://github.com/openai/openai-realtime-console/blob/main/client/assets/openai-logomark.svg` (OpenAI-owned repository; byte-identical copy also at `https://github.com/openai/openai-realtime-agents/blob/main/public/openai-logomark.svg`) | 2026-09-19 | `a2653cd27f20a4e764edf51b740f90e46a86aaf0819b60a23027e505bd100740` |
| `claude-spark-clay.svg` | Claude Spark — Clay (Anthropic press kit › Anthropic logos › Claude logos › 3 Claude Spark › SVG) | `https://www.anthropic.com/press-kit` (redirects to `https://www-cdn.anthropic.com/ae59ca4ca194dac9c9dc3bc78c5829468cb0e8af.zip`), linked from the Anthropic Newsroom `https://www.anthropic.com/news` (“Download press kit”) | 2026-09-19 | `6d53db4be375e899c937c26cf16684a80d6e869b1928d72b37748bef2560e219` |
| `openrouter-glyph-grape.svg` | OpenRouter glyph — Grape (light backgrounds) | `https://openrouter.ai/brand/logos/transparent/glyph/svg/glyph-grape.svg` (listed on `https://openrouter.ai/brand`) | 2026-09-19 | `5b49593d44e6aa41011be377e182cd89e57473f1948e0dfb128f99a92adfc68d` |
| `openrouter-glyph-volt.svg` | OpenRouter glyph — Volt (dark backgrounds) | `https://openrouter.ai/brand/logos/transparent/glyph/svg/glyph-volt.svg` | 2026-09-19 | `0d22462e4f2835a5a5b9000af0a55fc9238e39996100f54706e41ec45b9d1727` |
| `openrouter-glyph-ink.svg` | OpenRouter glyph — Ink (light backgrounds) | `https://openrouter.ai/brand/logos/transparent/glyph/svg/glyph-ink.svg` | 2026-09-19 | `91be6b8a91745f089bfe42b89a5cbcd4b666fca6473610f9a6c11a31bd7523bc` |
| `openrouter-glyph-cloud.svg` | OpenRouter glyph — Cloud (dark backgrounds) | `https://openrouter.ai/brand/logos/transparent/glyph/svg/glyph-cloud.svg` | 2026-09-19 | `385bbf00cd5718ad652fdfc05b4b4e7d0ea3a834cfd807e1133d3bee2b9a7c81` |

---

## OpenAI logomark (`openai-logomark.svg`) — used for Codex

- **Geometry:** `viewBox="0 0 320 320"`, single path, no fill attribute (renders black by default).
- **Why this source:** OpenAI’s brand page `https://openai.com/brand/` (and `https://platform.openai.com/brand-assets/…`) returned HTTP 403 to every non-browser fetch attempted on 2026-09-19, so the mark was taken from OpenAI’s own GitHub repositories, where the identical file ships in two projects. The repositories are MIT-licensed as **code**; that license does not cover the trademark, which remains OpenAI’s.
- **Published guidance (recorded from the search-engine index of `openai.com/brand/`; not machine-verifiable at retrieval time):** permission to use OpenAI marks is limited to adherence with the brand guidelines, is non-exclusive and non-transferable, and OpenAI’s marks must not be featured more prominently than your own name or marks. Contact for permission and questions: `partnercomms@openai.com`.
- **Modification / recoloring:** treat as **not permitted**. The mark is monochrome; UsageTool renders it only in pure black (light appearance) or pure white (dark appearance), never tinted, and never distorted. No template/menu-bar variant is created.
- **Codex:** OpenAI publishes no independent Codex product mark in its brand assets or in the `openai/codex` repository (which contains only a raster splash image). Per the design brief the OpenAI mark is shown with the visible label **“Codex”**; nothing was invented or traced.
- **Intended production use:** asset-catalog image `Provider/OpenAI`, `renderingMode(.original)`, 14 × 14 pt inside the 24 pt provider tile, `accessibilityHidden(true)`.
- **Unresolved caveat:** a human should open `https://openai.com/brand/` in a browser and confirm the current logo terms (black/white usage, clear space, prominence rule) before release.

## Claude Spark — Clay (`claude-spark-clay.svg`)

- **Geometry:** `viewBox="0 0 94 94"`, single path, `fill="#D97757"`.
- **Source:** Anthropic’s official press kit, the only first-party download of the Claude marks. The kit ships no license file; use is governed by the **Anthropic Trademark Guidelines** (`https://www.anthropic.com/legal/trademark-guidelines`, effective August 1, 2024), which state, in summary: Anthropic’s trademarks may be used only as specifically permitted by Anthropic; **no alterations (changes to color, font, proportion, or otherwise) are permitted**; do not place the mark on a background that interferes with its readability; maintain reasonable space around it; do not add a trademark symbol; do not imply sponsorship, endorsement or affiliation. The Claude Code documentation (`https://code.claude.com/docs/en/legal-and-compliance`) adds that one may accurately say in plain text that a product runs Claude Code, but may not use the Claude Code or Anthropic names or logos as part of one’s own product/feature/company name or logo, or in a way that suggests Anthropic built, endorses, or is partnered with the product; other uses are governed by the Trademark Guidelines and require written permission. Business inquiries: `marketing@anthropic.com`.
- **Modification / recoloring:** **not permitted.** UsageTool uses the single official Clay colorway in both light and dark appearance, never tints it, never creates a monochrome/template variant, and never dims it for state.
- **Intended production use:** asset-catalog image `Provider/ClaudeSpark`, `renderingMode(.original)`, 14 × 14 pt inside the 24 pt provider tile with ≥ 5 pt clear space, `accessibilityHidden(true)`; the visible label is always “Claude” with the caption “Last reported by Claude Code”.
- **Not used from the kit:** the Claude wordmark logos, the Claude Code logo, the gradient app icon, and the Anthropic logos (not needed for a 24 pt provider tile).

## OpenRouter glyph — Grape / Volt / Ink / Cloud (`openrouter-glyph-*.svg`)

- **Geometry:** `viewBox="0 0 1024 730"`, single path; the four files are geometrically identical and differ only in fill: Grape `#7624F4` (light backgrounds), Volt `#C8FF00` (dark backgrounds), Ink `#03080A` (light backgrounds), Cloud `#FCFCFE` (dark backgrounds).
- **Source:** OpenRouter’s official brand page `https://openrouter.ai/brand` (“Every configuration of the OpenRouter mark, ready to use. SVG scales anywhere; PNGs are exported at 2×.”). A bulk download is also offered at `https://openrouter.ai/brand/logos/openrouter-logos.zip`.
- **Published guidance:** “Please don’t stretch, recolor, or remix the marks.” The page states no explicit license grant and no explicit trademark clause; treat the marks as OpenRouter’s trademarks used as published.
- **Modification / recoloring:** **not permitted** (“don’t … recolor”). UsageTool uses only the published colorways: Grape on light, Cloud on dark (Volt and Ink are kept for completeness and are equally official). No monochrome/template variant is created.
- **Intended production use:** asset-catalog images `Provider/OpenRouter-Grape` and `Provider/OpenRouter-Cloud`, `renderingMode(.original)`, 14 × 10 pt (aspect preserved) inside the 24 pt provider tile, `accessibilityHidden(true)`.

---

## How the marks are used in the design (summary)

- Marks appear only inside the 24 pt provider tile in the popover and Settings, always next to the visible provider name; the name, not the mark, is the accessibility label.
- Marks are never tinted, dimmed, hatched, outlined, rotated, or distorted; status is conveyed by the tile, pills, SF Symbols and text.
- No provider mark is used in the menu bar (menu-bar images are monochrome templates, which would recolor the marks). The only menu-bar image is UsageTool’s own `usage.gauge` symbol.
- The mockups `Design/UsageTool-Popover.svg` and `Design/UsageTool-Settings.svg` embed the same path geometry as `<symbol>` definitions so they stay self-contained.
