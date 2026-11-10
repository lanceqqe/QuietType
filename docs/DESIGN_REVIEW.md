## verdict

Scoped verdict pass for the three findings from the initial finish review. Both supplied recaptures are valid 1840 × 1420 images of the 920 × 710-point native window. Source inspection is limited to those fixes; no new defect hunt was performed.

1. **Resolved — wrapped ghost alignment.** In `.impeccable/review/writing-fixed.png`, the wrapped “Но” aligns with the entered text's left origin; the first line remains attached to the caret with matching font and baseline after word acceptance. `PreviewTextView.updateGhost` now includes `textContainer.lineFragmentPadding` in its left origin.
2. **Resolved — caret changes.** `.impeccable/review/writing-caret-middle.png` shows the continuation hidden with the caret moved one character left. Source updates on `textViewDidChangeSelection` and requires an empty selection at the document end, restoring eligibility when the caret returns there.
3. **Resolved — stale exclusion paths.** `GhostTextView.configure` now explicitly sets `container.exclusionPaths = []` when the offset is zero. This deterministic state reset is verified from source; the screenshots establish the nonzero-offset rendering, rather than separately demonstrating the zero-offset transition.

No regressions observed in this fix batch.

## remaining

Clear for the three scored fixes. This ship verdict covers the scored fixes, not the whole surface. Telegram font, text-origin placement, suffix protection and mouse/scroll dismissal remain user-side verification; the playground screenshots do not establish those behaviors. TCC is reported granted and preserved through the signed rebuild, rather than independently tested in this review.

disposition: ship
