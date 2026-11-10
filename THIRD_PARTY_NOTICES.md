# Third-party notices

QuietType is an independent implementation inspired by the workflow described at https://cotypist.app. It does not include Cotypist code, assets, prompts or model bundles.

## Model

- Qwen3 0.6B by the Qwen team, Apache License 2.0: https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/LICENSE
- Core ML conversion: ANEMLL, https://huggingface.co/anemll/anemll-Qwen3-0.6B-ctx512_0.3.0
- Pinned revision: `8b6eab61588f28e967bfe296379f15e1431166d4`.
- ANEMLL conversion project: MIT, https://github.com/Anemll/Anemll/blob/main/LICENSE.

Model files are downloaded separately. SHA-256 values in ModelStore.swift identify the tested artifacts. The metadata in this early ANEMLL conversion does not provide a reproducible base-versus-instruct provenance; do not claim it is the same model used by Cotypist or an optimized autocomplete fine-tune.

## Swift packages

Direct: Hugging Face swift-transformers, Apache 2.0: https://github.com/huggingface/swift-transformers.

Transitive packages and their license texts are pinned by Package.resolved and available under `.build/checkouts` after resolution: swift-jinja, swift-huggingface, yyjson, swift-collections, swift-crypto, swift-asn1, EventSource. Apple packages use Apache 2.0 with Runtime Library Exception where specified; consult each checked-in license before redistribution. Reproduce third-party license texts in a distributed release.

The application icon is drawn by scripts/make-icon.swift using SF Symbols and AppKit; no third-party image assets are included.
