import CryptoKit
import Foundation

public enum ModelAssets {
    /// ANEMLL conversion of Gemma 3 1B (instruction-tuned), 6-bit FFN and LM head, argmax head.
    public static let repository = "anemll/anemll-google-gemma-3-1b-it-ctx4096_0.3.5"
    public static let revision = "a1b00f628f348c8ff55c9fe088e5db97535fd567"
    public static let displayName = "Gemma 3 · 1B"
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuietType/Models/Gemma3-1B")
    /// Calibrated on this model; another model needs its own floors (see docs/VALIDATION.md).
    public static let profile = DecodingProfile(firstFloor: 0.2, wordFloor: 0.3, innerFloor: 0.1)
    public struct Asset: Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }
    public static let files: [Asset] = [
        Asset(path: "config.json", size: 66, sha256: "57e37d62b88fe19bf8edfcc64189adeabd412b05ae6ce8c8f605bc36f1e6c677"),
        Asset(path: "gemma3_FFN_PF_lut6_chunk_01of01.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "5428848963a0f646e91d7e7f14334b6b7fe57eab46c32e7af1aeb43121536a0e"),
        Asset(path: "gemma3_FFN_PF_lut6_chunk_01of01.mlmodelc/coremldata.bin", size: 1655, sha256: "ebf9f991115223c6521704e80eb9b03690d0dae486f8727f199bc4eabe097482"),
        Asset(path: "gemma3_FFN_PF_lut6_chunk_01of01.mlmodelc/metadata.json", size: 18245, sha256: "8fa3fc9eae0c6c6c53559fa04efceb4a1d1492aeac45245c2938f64acd9fccb8"),
        Asset(path: "gemma3_FFN_PF_lut6_chunk_01of01.mlmodelc/model.mil", size: 4509841, sha256: "822060a955a3d25733e80d748cd9bacf19e0e17d088d16151d466eec601ae90c"),
        Asset(path: "gemma3_FFN_PF_lut6_chunk_01of01.mlmodelc/weights/weight.bin", size: 555097216, sha256: "faddf2fb58eb95da2b2160b560968a448bb5aec5e84e706012d0332cda25eb6a"),
        Asset(path: "gemma3_embeddings_lut8.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "7478f61e509dffd5dc8d9e01806296e2e05e45c8c88cf3ce84b872375a007036"),
        Asset(path: "gemma3_embeddings_lut8.mlmodelc/coremldata.bin", size: 587, sha256: "1c69b647bec6f40ae75d785fc4f34cd72c24005fbadf40a89c835f71984dbe54"),
        Asset(path: "gemma3_embeddings_lut8.mlmodelc/metadata.json", size: 2054, sha256: "4478777a70eb5050bf17d27d74854b8d1fb3eac225a656d88a55244d345afc41"),
        Asset(path: "gemma3_embeddings_lut8.mlmodelc/model.mil", size: 2315, sha256: "910d986c8ab72c4bebf15d6df770e7958c395b0ea3c1a578e14598c46631bc5b"),
        Asset(path: "gemma3_embeddings_lut8.mlmodelc/weights/weight.bin", size: 603979904, sha256: "573ae2fd94e5b742800087ebc6d11c6531f0c3955a911e71d7844433a60fcaa5"),
        Asset(path: "gemma3_lm_head_lut6.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "476e22675a5e6eb52a2a560ea66a0f36cf0e367d8af3fee7000feacb6e3739e2"),
        Asset(path: "gemma3_lm_head_lut6.mlmodelc/coremldata.bin", size: 600, sha256: "1227384eea5776e75f3f454bea85dd2877aae7e3c3865435478729e6da3759da"),
        Asset(path: "gemma3_lm_head_lut6.mlmodelc/metadata.json", size: 2457, sha256: "5f8788a6cd7da7d4f30a23f82917384f6a26caa80b0ee42e25e19796baf90956"),
        Asset(path: "gemma3_lm_head_lut6.mlmodelc/model.mil", size: 56788, sha256: "774fd3191f0b79c5f9a25410602f5b53a0b0ed46438cae39c5ee2005a3607c3d"),
        Asset(path: "gemma3_lm_head_lut6.mlmodelc/weights/weight.bin", size: 234883136, sha256: "5e5141ce851f2d8f53b241e7aac9e10655769c3a0b1ffa30940cba7aba887d6a"),
        Asset(path: "meta.yaml", size: 2238, sha256: "377114b49a7213f6212707347ea05ebdb07fc61b5ea6f812d085c2433430f535"),
        Asset(path: "tokenizer.json", size: 33384568, sha256: "4667f2089529e8e7657cfb6d1c19910ae71ff5f28aa7ab2ff2763330affad795"),
        Asset(path: "tokenizer_config.json", size: 1156999, sha256: "bfe25c2735e395407beb78456ea9a6984a1f00d8c16fa04a8b75f2a614cf53e1"),
    ]
    public static var downloadBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public static var isInstalled: Bool {
        guard let marker = try? String(contentsOf: directory.appendingPathComponent(".ready"), encoding: .utf8),
              marker == revision else { return false }
        return files.allSatisfy { asset in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(asset.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == asset.size
        }
    }
}

public enum InstallationFailure: LocalizedError {
    case badDownload(String), busy
    public var errorDescription: String? {
        switch self {
        case .badDownload(let path): "Файл модели повреждён: \(path). Повторите установку."
        case .busy: "Установка уже выполняется."
        }
    }
}

public actor ModelStore {
    private var installing = false
    public init() {}

    public func install(from localDirectory: URL? = nil,
                        progress: @Sendable (String, Double) -> Void) async throws {
        guard !installing else { throw InstallationFailure.busy }
        installing = true
        defer { installing = false }
        if ModelAssets.isInstalled { return }
        let fm = FileManager.default
        let destination = ModelAssets.directory
        let stage = destination.deletingLastPathComponent().appendingPathComponent("install-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var completed: Int64 = 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for asset in ModelAssets.files {
            try Task.checkCancellation()
            progress(asset.path, Double(completed) / Double(ModelAssets.downloadBytes))
            let target = stage.appendingPathComponent(asset.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let localDirectory {
                try fm.copyItem(at: localDirectory.appendingPathComponent(asset.path), to: target)
            } else {
                let url = URL(string: "https://huggingface.co/" + ModelAssets.repository + "/resolve/" + ModelAssets.revision + "/" + asset.path)!
                let (temporary, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallationFailure.badDownload(asset.path) }
                try fm.moveItem(at: temporary, to: target)
            }
            try verify(target, asset: asset)
            completed += asset.size
        }
        try Task.checkCancellation()
        try ModelAssets.revision.write(to: stage.appendingPathComponent(".ready"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: stage, to: destination)
        progress("Готово", 1)
    }

    private func verify(_ url: URL, asset: ModelAssets.Asset) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == asset.size else { throw InstallationFailure.badDownload(asset.path) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { throw InstallationFailure.badDownload(asset.path) }
    }
}
