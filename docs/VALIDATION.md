# Validation — 10 November 2026

Environment: Apple M5, macOS 27.2, Xcode 27.2, Swift 6.4.2. Deployment target: macOS 26.0, arm64 executable.

## Passed

- `swift test`: 10 tests. Russian word acceptance and spacing; UTF-16 emoji boundaries; energy policy limits; default and custom exclusions; bounded cache clearing; control-token and broken-Unicode suppression; removal of budget-truncated words; parsing actual AXFont metadata and preserving native fonts.
- Actual Core ML generation in Russian and English using the downloaded ANEMLL Qwen3 0.6B conversion, with CPU + Neural Engine configuration for all model components.
- ModelProbe compared warm-prefix completions with completions after a fresh KV reset for four built-in phrases. All outputs matched.
- Model installation from the downloaded artifact directory: all 17 files passed pinned SHA-256 and size verification. Installed under `~/Library/Application Support/QuietType/Models/Qwen3-0.6B`.
- Signed release `.app` built successfully; `codesign --verify --deep --strict` passed. The final build uses the existing Apple Development identity. Accessibility trust was restored by the user after removing the old ad-hoc identity's TCC entry; the following certificate-signed rebuild preserved access.
- Native app launched with dependency resources and model loading successfully. Real Russian and English suggestions appeared in its editor.
- Native editor Tab accepted individual words; two consecutive Tab presses appended two words and retained the remaining suggestion.
- Inline ghost screenshot: entered and suggested text share a baseline and font; wrapped text now aligns to the actual text origin. Moving the caret left hid the suggestion. Returning to the eligible end restores it.
- Independent UI review scored the three specific alignment/selection/exclusion-path fixes resolved. See DESIGN_REVIEW.md; this verdict is scoped to those fixes, not every app.

## Runtime observations

Early debug probes: 12 generated tokens took approximately 270–435 ms; warm 8-token completions took approximately 163–199 ms. Native app checks returned approximately 263–414 ms for its configured generation length. These measure model calls, excluding debounce and startup. Initial backend specialization took approximately 33–35 seconds; later launches benefit from Core ML caches.

## Telegram correction

User observed suggestions in Telegram but reported overlay-like placement. Found and fixed a real typography bug: Accessibility uses `AXFont` dictionaries and `AXForegroundColor` CGColor values, whereas the first implementation only read AppKit attributed-string keys. Added tests for this parsing. Host line origins now account for available AX line geometry, rather than a fixed inset. Existing text after the cursor prevents rendering over it. Mouse clicks and scrolling dismiss the drawing immediately.

The updated Telegram appearance still needs confirmation in the user's live typing workflow. No claim of pixel-for-pixel Cotypist parity is made solely from source changes or the internal editor screenshot. Public Cotypist press screenshots/demo were inspected as visual reference, not included in the shipped app.

## Limits and remaining manual checks

- Automated background app interaction did not establish reliable foreground TextEdit Tab interception. Do not report cross-app acceptance as passed on that evidence. The synthetic TextEdit test document was saved in `.model-cache/QuietType-TextEdit-QA.rtf`.
- A manual compatibility matrix for Mail, Telegram, Safari/Chrome textareas, Notes and Electron applications is not yet complete.
- CPU/ANE operator placement fraction, joules per suggestion and comparative Cotypist latency were not measured. `.cpuAndNeuralEngine` excludes GPU but does not prove that every operation uses ANE.
- macOS 26 compatibility is based on deployment target and APIs; this session ran on macOS 27.2.
- Screen context, model comparison research and personalization were deferred by the user.

## Follow-up: empty-field regression and short completions

- Reproduced a structural bug: focus observation was incorrectly gated on an already nonempty generation context, so an empty newly focused field never subscribed to value/selection changes. Split focus eligibility from generation eligibility; password/protected fields remain excluded. Added regression tests.
- Added a cancellable, one-shot 30 ms post-key follow-up for custom editors that omit Accessibility change notifications. It is superseded by real AX events and creates no idle polling. Escape cancels pending work without rescheduling it.
- Default output is capped at three words; economy/Low Power/thermal-constrained output at two. Generation ends when the word boundary is available, rather than generating a long answer and clipping it only in the UI.
- 13 Swift Testing tests pass. Real ModelProbe returns no more than three words on all four Russian/English cases and still matches warm vs reset KV output. On this M5 run, model calls took 63–138 ms and warm calls 47–95 ms; these are latency measurements, not energy measurements.
