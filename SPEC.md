# QuietType specification

## Objective
Build an installable native macOS autocomplete app for Russian and English, independent of Apple Intelligence. Local neural inference with Core ML CPU + Neural Engine configuration. Do not imitate Cotypist branding or promise compatibility with every text field.

## Modules and order
1. `inference`: validate a downloadable Core ML model (ANEMLL layout), tokenizer, cancellation, bounded generation.
2. `completion`: context truncation, partial acceptance, cache, debounce, battery/thermal policies.
3. `accessibility`: observe focused fields and changes, caret panel, Tab acceptance, reject stale contexts, exclude secure fields and sensitive apps.
4. `app`: menu bar, Russian setup/settings, model download, playground, real session metrics.

## Commands
`swift test` — deterministic behavioral tests.
`swift run ModelProbe <model-directory>` — actual Russian and English inference.
`./scripts/build-app.sh` — build arm64 release app at dist/QuietType.app.
`open dist/QuietType.app` — launch.

## Structure and style
Sources/QuietTypeCore holds model runtime and pure completion policy. Sources/QuietType holds main-actor AppKit and SwiftUI integration. Tests/QuietTypeCoreTests uses Swift Testing. Prefer value types for immutable snapshots, an actor for inference, explicit errors and cancellation.

```swift
guard snapshot.selection.length == 0 else { return nil }
try Task.checkCancellation()
```

## Success criteria
- Compiles and packages as an arm64 .app without external Python runtime.
- Real local Russian and English generation; missing models produce actionable setup, never fake output.
- No idle polling for text; debounce changes and keep at most one inference active.
- Tab inserts one word, Option-Tab inserts the suggestion; Escape dismisses. A visible suggestion always consumes Tab; the event-tap callback makes no Accessibility calls. Every key, click, focus or text change invalidates the suggestion; insertion checks the frontmost process.
- Hosts that hide their text field from Accessibility (allowlist, currently empty) are followed by an in-memory keystroke buffer and a pill; hosts without caret geometry get the pill next to the field.
- Decoding re-predicts the word under the caret, blocks repeated token n-grams and cuts at low confidence; an empty suggestion is a valid result.
- Suggestions are dim inline ghost text, with the host font when available, no bubble, border or badge. Preserve the remainder after word acceptance.
- Default completion is at most three words; constrained energy modes use at most two. Stop inference at the completed word boundary instead of producing a long continuation.
- Observe editable fields on focus even when empty; only generation waits for three input characters. Custom editors without AX notifications receive a single cancellable post-key follow-up, never idle polling.
- Never read secure/password fields; default exclusion of password managers and terminals. Never log or persist typed text.
- Respect low power and thermal state; bound context and output; release model when explicitly unloaded.
- No cloud text requests. Network is only for explicit model setup.

## Verification
Unit tests cover UTF-16 boundaries, Russian partial words, acceptance, privacy gate, stale contexts, cache, energy policies. Real model probe covers multilingual inference and latency. Accessibility behavior requires user-granted macOS permissions and manual cross-app verification. Record limits honestly in README.

## Boundaries
Always validate model files and context, propagate inference errors, preserve clipboard. Never auto-grant permissions, record user text, use private ANE APIs, or publish performance numbers from another machine as our own.

## Deferred by user
Screen/window context, model comparison research, personalization, and broad app-specific compatibility extensions. The basic local completion path takes priority.
