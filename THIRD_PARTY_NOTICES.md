# Third-party notices

QuietType is an independent implementation inspired by the workflow described at https://cotypist.app. It does not include Cotypist code, assets, prompts or model bundles.

## Model

- Gemma 3 1B (instruction-tuned) by Google, distributed under the Gemma Terms of Use: https://ai.google.dev/gemma/terms. These are not an open-source licence; they carry use restrictions (Prohibited Use Policy) that pass on to anyone who redistributes the weights.
- Core ML conversion: ANEMLL, https://huggingface.co/anemll/anemll-google-gemma-3-1b-it-ctx4096_0.3.5 (the repository card is tagged MIT; that covers the conversion, not Google's weights).
- Pinned revision: `a1b00f628f348c8ff55c9fe088e5db97535fd567`.
- ANEMLL conversion project: MIT, https://github.com/Anemll/Anemll/blob/main/LICENSE.

Model files are downloaded separately by each user from Hugging Face; QuietType does not bundle them. SHA-256 values in ModelStore.swift identify the tested artifacts. Do not claim it is the same model used by Cotypist or an autocomplete fine-tune: it is a chat model driven as a plain text continuer.

Earlier builds used Qwen3 0.6B (Apache 2.0, https://huggingface.co/anemll/anemll-Qwen3-0.6B-ctx512_0.3.0); it is no longer downloaded.

## Swift packages

Direct: Hugging Face swift-transformers, Apache 2.0: https://github.com/huggingface/swift-transformers.

Transitive packages and their license texts are pinned by Package.resolved and available under `.build/checkouts` after resolution: swift-jinja, swift-huggingface, yyjson, swift-collections, swift-crypto, swift-asn1, EventSource. Apple packages use Apache 2.0 with Runtime Library Exception where specified; consult each checked-in license before redistribution. Reproduce third-party license texts in a distributed release.

The application icon is drawn by scripts/make-icon.swift using SF Symbols and AppKit; no third-party image assets are included.
