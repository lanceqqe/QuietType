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

## Follow-up: Telegram, loops, latency, Tab in browsers

- Accessibility probe of Telegram for macOS (`ru.keepcoder.Telegram`): the focused element is the `AXWindow`; the tree contains no text area for the message field. Suggestions there now come from a keystroke buffer and are shown as a pill. **Not verified live**: typing into the user's chats was deliberately not automated.
- Decoder: token healing, repeated n-gram blocking, confidence cut-off. `ModelProbe --try --loop` on four phrases: accepting suggestions 40 times in a row no longer cycles; generation stops with an empty suggestion instead. Warm and cold KV results still match. Model calls on M5: 40–145 ms.
- Latency: debounce 400 → 110 ms (50 in responsive mode); one field read per request instead of one per notification, partial and final result; typed-through suggestions need no inference; context window start moves in blocks so the KV cache is reused in long texts.
- Tab: a visible suggestion consumes Tab without Accessibility calls inside the event tap (the previous revalidation could fail or time the tap out in browsers, letting Tab through). Web content is inserted with Unicode key events. **Not verified live** in Chrome/Safari in this session.
- 17 Swift Testing tests pass.

## Telegram, corrected diagnosis

The earlier probe ran while the message field was not focused; the conclusion that Telegram hides the field was wrong. Live log from the user's typing: Telegram exposes an `AXTextArea`, but its caret rectangle sits exactly one caret height above the text (caret y 116–132 in a field spanning 95–121), which failed the caret-inside-field check and suppressed the suggestion. Telegram's caret is now shifted down by one line; other hosts with an out-of-field caret fall back to the pill. Telegram was removed from the keystroke-fallback list. `~/Library/Logs/QuietType.log` records pipeline stages without typed text.

## Follow-up: model comparison and switch to Gemma 3 1B

Goal: more sensible Russian suggestions within roughly 200 ms per call. Same decoder for every model; 20 prefixes (12 Russian, 8 English, 6 cut mid-word) via `ModelProbe --try`, cold KV per phrase, up to three words, after a warm-up run. Raw logs: `.model-cache/cmp-*.log`.

| Model (ANEMLL, 6-bit) | Download | FFN chunks / LM head | Call time, 20 phrases | Per token |
|---|---|---|---|---|
| Qwen3 0.6B ctx512 (previous) | 0.76 GB | 1 / 16 logit slices | 40–146 ms | ≈15 ms |
| Qwen3 1.7B ctx2048 | 1.95 GB | 2 / 16 logit slices | 133–713 ms | ≈40 ms |
| Gemma 3 1B it ctx4096 (chosen) | 1.43 GB | 1 / argmax, 16 slices | 49–132 ms | ≈16 ms |

- Quality, judged by reading the outputs (not a metric): Qwen3 0.6B produced «в ближней районе», «с отвелем на», «обсудим обсуждение о» and three empty suggestions. Qwen3 1.7B and Gemma 3 1B both produced grammatical, plausible Russian on all 12 Russian prefixes, with one exception each way: Gemma completed «на соглас» as «согласность» (1.7B: «согласование») and «late repl» as «replies» (both Qwens: «reply»).
- Qwen3 1.7B was rejected on latency only: typical suggestions took 280–520 ms.
- Gemma 3 4B QAT (4.4 GB, three FFN chunks) was not downloaded or measured.
- `LocalModel` now discovers the layout from the model directory: FFN chunk count with one KV state per chunk, causal-mask width, LM head kind, stop tokens, BOS. Context use is capped at 512 tokens, which also keeps Gemma inside its 512-token local-attention window, so the conversion's `*_rotate` functions are never needed.
- Gemma's argmax head exposes only the best token of each of 16 vocabulary slices. Consequences: the confidence value is an upper bound (normalised over 16 maxima), and token healing picks among 16 candidates. Floors recalibrated from a per-token trace of the 20 phrases to 0.30 / 0.30 / 0.20 (first token / word start / inside a word); with them «когда будет» yields no suggestion instead of «открыта новая торговая». The Qwen3 0.6B floors were 0.09 / 0.08 / 0.05 on a true softmax.
- `ModelStore` installs `anemll/anemll-google-gemma-3-1b-it-ctx4096_0.3.5` at revision `a1b00f62…`: 19 files, 1,433,099,398 bytes, each checked for size and SHA-256 (hashes also matched the Hugging Face LFS object ids at download time). `ModelProbe --install .model-cache/gemma1b` passed and installed to `~/Library/Application Support/QuietType/Models/Gemma3-1B`.
- `ModelProbe` on the installed model: five built-in prefixes, including one longer than a 64-token prefill batch (92 reused tokens), gave identical warm and cold-KV output; calls took 64–141 ms. `--try --loop` on five phrases ended every sentence without cycling. The same built-in probe also passed on Qwen3 0.6B after the refactor.
- 17 Swift Testing tests pass (none exercise Core ML; model behaviour is covered only by ModelProbe).
- First load of the new model took 80–106 s (one-time Neural Engine specialisation per install path), later loads about 1 s. The first call after load took about 210 ms.
- **Not verified**: live typing in other applications with the new model, memory footprint, energy, and behaviour beyond 512 tokens of context. Gemma weights fall under Google's Gemma Terms of Use rather than Apache 2.0; see THIRD_PARTY_NOTICES.md.


## 0.2.0: installer, style memory, compute fallback, updater (11 November 2026)

Verified:
- 22 unit tests pass, including style-memory recall, vocabulary completion, secret/number filtering, style card selection and version comparison.
- `ModelProbe --memory <file> --try …`: with five sample phrases in front, completions follow the user's vocabulary ("давай завтра " → "по лендингу"; "Я ща " → "посмотрю, как у" instead of nonsense); KV reuse of the sample block confirmed (reused 67–74 tokens).
- `ModelProbe --no-ane`: the same Gemma files load and generate on CPU + GPU (M5): first call 24.5 s, then 0.5–2 s.
- DMG mounts, contains the app, the Applications link and the install notes; the signature verifies.

Not verified:
- The Neural Engine load failure itself was reported from an M1 Pro on macOS 27.0 and not reproduced here; the fallback was exercised only by skipping the Neural Engine on an M5.
- Gatekeeper's first-launch prompt (Gatekeeper is disabled on the build machine).
- Live learning from typing in other apps and the end-to-end self-update (needs a published newer release).

## 0.3.0: screen context (11 November 2026)

Verified:
- 24 unit tests pass, including assembly of window text (column filter, row merging, cut to the lines nearest the field, secret filter).
- `ModelProbe --screen <file>`: with a chat above the field, "Ок, уголь " → "и мангал, давай", "Привет! Да, " → "я свободен, и"; with a letter, "Hi Anna, thanks for the draft. " → "I've reviewed section". Calls 97–207 ms; the default probe (warm/cold KV equality) still passes with the context limit raised to 1024 tokens.
- Live, Claude desktop app: 488–592 characters read through Accessibility in 118–146 ms on focus.

- Live, Telegram with Screen Recording granted: 465 characters recognised from the picture of the window in 493 ms (ScreenCaptureKit + Vision).

Not verified:
- The recognised text itself was not inspected (it is never logged), only its length and timing.
- Quality of suggestions with real screen text in everyday use; Safari and Mail were only probed for the amount of exposed text.

## 0.3.2: longer suggestions (11 November 2026)

- Up to 6 words (3 when constrained). The first three words are no longer cut by `wordFloor`; `firstFloor` 0.3 → 0.2, `innerFloor` 0.2 → 0.1.
- Gemma's probability estimate (an upper bound from the argmax head) is bunched: floors between 0 and 0.25 give identical output on 16 phrases, 0.3 cuts most suggestions to 1–2 words. So the cut is now positional rather than a finer threshold.
- Cost, seen on the same phrases: without screen context or style memory the longer tail is often invented ("Я сегодня не смогу, потому что " → "у меня сегодня день рождения!"). Calls 70–310 ms.

## 0.3.3: the lead as a request, measured floors (11 November 2026)

- Screen text and the style sample are wrapped in Gemma's chat turns as a request to finish the user's message; the field's text opens the model's own turn. Teacher-forced top-1 on the same texts: Russian 39.9 % → 42.4 %, English 43.0 % → 46.8 %. With a chat on screen the raw layout ended suggestions after one or two words (the model predicted the end of a short line, then a timestamp); the request does not.
- `ModelProbe --eval` types 30 Russian messages word by word (282 positions after a word, 120 inside one) and compares the suggestion with what was written. Before: shown at 97 % of positions after a word, first word right 30 %, 106 right of 803 words offered. With `firstFloor` 0.65 (now also applied to the first word after a space), `wordFloor` 0.6, `innerFloor` 0.2, `freeWords` 1: shown 55 %, first word right 43 %, 87 right of 360. Inside a word: first word right 61 % → 69 %, 94 of 313 → 90 of 192.
- The benchmark has no screen text or style sample; on it the request alone is not better than raw text (first word right 43 % against 49 % at the same floors, within the noise of 282 positions).

Not verified:
- Everyday use in real apps; the screen scenarios were hand-written files, not text read from a window.
- Known misses: a word finished wrongly when the screen is off topic ("Отчёт скину" → "лся"), an occasional assistant-style reply ("Could you please send me the" → "message?").
