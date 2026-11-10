---
name: QuietType
description: Native Mac writing assistance that continues the host text quietly.
typography:
  title:
    fontFamily: system-ui
    fontSize: 28pt
    fontWeight: 700
    letterSpacing: -0.6pt
  brand:
    fontFamily: system-ui
    fontSize: 20pt
    fontWeight: 600
  editor:
    fontFamily: system-ui
    fontSize: 16pt
  shortcut:
    fontFamily: monospace
rounded:
  editor: 12pt
  setup: 12pt
  exclusion-editor: 8pt
  error: 10pt
spacing:
  detail-inset: 32pt
  detail-stack: 26pt
  section-stack: 24pt
  editor-stack: 13pt
  group-inset: 16pt
  shortcut-inset: 12pt
components:
  writing-editor:
    typography: '{typography.editor}'
    rounded: '{rounded.editor}'
    height: 210pt
  setup-container:
    rounded: '{rounded.setup}'
  error-banner:
    rounded: '{rounded.error}'
    padding: 14pt
---

# Design System: QuietType

## Overview

**Creative North Star: "Native Mac writing assistance"**

QuietType is a native macOS utility built with SwiftUI and AppKit. System typography, semantic colors, SF Symbols and standard controls establish its visual language. Russian interface labels coexist with Russian and English writing. QuietType is a working name, not an established brand identity.

The writing surface belongs to the user. Suggested text continues directly from the caret in the host typeface, dimmed to distinguish it from committed text. Setup and controls live in a separate native window and menu bar menu.

**Key Characteristics:**
- Native sidebar navigation and system controls.
- Appearance-aware surfaces with a restrained system teal tint.
- Transparent, noninteractive ghost glyphs aligned with host text.
- A clear title, secondary explanation and contextual action hierarchy.

Evidence: `Sources/QuietType/ContentView.swift`, `Sources/QuietType/SuggestionPanel.swift`, `Sources/QuietType/QuietTypeApp.swift`, and `Sources/QuietTypeCore/HostTextStyle.swift`. `PRODUCT.md` establishes native platform and system appearance; `docs/surface.md` records the surface direction. `.impeccable/review/writing-fixed.png` supports the dark writing-window composition, baseline and wrapped-line alignment. `writing-caret-middle.png` verifies that moving the caret into existing text hides the continuation. External Telegram layout remains a separate manual compatibility check.

## Colors

Use native semantic colors resolved by macOS in the current appearance. Color primitives are recorded in the sidecar's `extensions.native.colors`: these AppKit and SwiftUI values cannot be faithfully represented as fixed CSS colors, so the frontmatter intentionally has no `colors` map. Do not derive production hex values or invented tonal ramps from a screenshot.

### Primary
- **System teal:** SwiftUI `.teal` is the window tint and marks assistance, completed setup and readiness. Native control rendering may also reflect system appearance and accent preferences.

### Neutral
- **Window surface:** `NSColor.windowBackgroundColor` behind the detail pane.
- **Text surface:** `NSColor.textBackgroundColor` behind the writing editor; SwiftUI `.background` in setup and exclusion containers.
- **Main ink:** inherited native primary text; host text color for external continuations, with `NSColor.labelColor` as fallback.
- **Secondary ink:** SwiftUI `.secondary` for explanation, metadata and inactive readiness; `NSColor.secondaryLabelColor` is the preview ghost fallback.
- **Separators:** SwiftUI `.separator`, softened on custom containers.
- **Status fill:** `.quaternary` with an opacity modifier for the status capsule.

Errors use native orange for the warning symbol and a faint orange background. They also include explanatory text and a dismiss control.

**The Semantic Appearance Rule.** Preserve dynamic native color roles rather than freezing the dark screenshot into a palette.

## Typography

The frontmatter owns explicit title, brand and preview editor values. Other interface text uses SwiftUI semantic roles: headline, title2, title3, body, subheadline, callout, caption and caption2. Respect their native metrics rather than creating an unrelated fixed scale. Shortcut values and excluded application identifiers use the system monospaced design. SF Symbols supply native interface iconography.

**The Host Continuation Rule.** Ghost text must use the host font and text color with reduced alpha, not a separate suggestion font. `HostTextStyle` prefers attributed native font/color, then Accessibility font/color attributes. Missing host metrics fall back to a system font derived from caret height, bounded by the implementation; this is compatibility recovery, not a universal typography token.

The test editor uses the explicit editor token. Its ghost uses the same font and native line height. External suggestions use host metrics and may therefore differ from the settings window's typography.

## Layout

The main window uses `NavigationSplitView`, a sidebar list and a vertically scrollable detail pane. Default window size is 920 × 710 points; minimum content size is 780 × 600 points. Sidebar width is constrained to 200–250 points with an ideal width of 215. Detail content is leading-aligned, padded by the detail-inset token and constrained to a maximum width of 820 points. There is no web breakpoint grid.

Use the frontmatter spacing tokens for their named contexts rather than treating them as a universal arithmetic scale. The editor scrolls vertically and tracks its available width. Its text-container inset is 14 points horizontally and 16 vertically; native line-fragment padding also participates in glyph alignment. The ghost's wrapped lines start at that same text origin, while its first line begins at the caret.

## Elevation & Depth

Native window chrome, sidebar selection, GroupBox and standard controls provide platform depth. Custom setup and writing containers use semantic surfaces and subtle separator strokes. The writing editor's separator opacity is 0.6; setup separators use 0.5. Status fill uses quaternary opacity 0.6. No custom shadow vocabulary is established.

**The Glyphs Only Rule.** The external suggestion panel is clear, borderless, shadowless and nonactivating. It draws only dim glyphs and ignores mouse events; never turn it into a bubble, card or tooltip.

## Shapes

Use the frontmatter corner tokens for custom editor, setup, exclusion and error containers. Readiness uses a native capsule with a small circular status indicator. Buttons, switches, menus, GroupBox, sidebar rows and window corners retain native shapes and states; do not extrapolate their appearance into custom fixed radii.

## Components

### Navigation and window controls

The sidebar uses standard selectable `Label` rows with SF Symbols. A toolbar switch pauses suggestions. Native selection, focus, hover and disabled treatment remain system-owned. The menu bar extra uses the text-cursor symbol when enabled and ready, otherwise pause-circle; its menu supplies toggles, window access and model controls.

### Buttons and forms

Generation and model actions use `.borderedProminent`; ordinary actions use native buttons and setup links use `.link`. The error dismiss action is `.plain`. Do not replace these with simulated HTML controls. Busy generation has a small native progress indicator; unavailable generation is disabled. Energy settings use a grouped native Form with Picker, Toggle and LabeledContent.

### Containers and status

Setup rows pair an icon, title, secondary explanation and contextual action, divided within one container. GroupBox groups model details and shortcuts. The status capsule pairs text with a six-point indicator so state is not communicated by color alone. The error banner combines an orange warning symbol, selectable message and accessible dismiss button.

### Writing editor and ghost continuation

The writing field is a plain AppKit `NSTextView` in an `NSScrollView`, not a fake text input. Ghost text is an inert drawing overlay rather than committed editor content. It uses foreground alpha 0.45, word wrapping and at most three lines. The external panel is constrained to host container and visible screen bounds. Its first line starts at the caret and following lines return to the container's text origin.

In the preview, show ghost text only for a collapsed selection at the end of the text; hide it when selecting or moving the caret elsewhere. Source includes the native line-fragment offset in wrapped-line placement. Both behaviors were verified in the final writing-fixed and writing-caret-middle runtime captures; see docs/DESIGN_REVIEW.md for the scoped review verdict.

## Do's and Don'ts

### Do:
- Do keep native semantic colors and system appearance dynamic.
- Do match ghost typography, line height and origin to the text being continued.
- Do use native controls, semantic type roles and SF Symbols.
- Do retain text labels alongside readiness and error indicators.

### Don't:
- Don't put ghost text in a bubble, card or shadowed panel.
- Don't treat a captured dark appearance as a fixed color palette.
- Don't use the settings editor's font as the universal external host font.
- Don't claim the existing screenshot verifies the later wrapping and selection fixes.
