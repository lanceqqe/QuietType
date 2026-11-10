import CryptoKit
import Foundation

public enum ModelAssets {
    public static let repository = "anemll/anemll-Qwen3-0.6B-ctx512_0.3.0"
    public static let revision = "8b6eab61588f28e967bfe296379f15e1431166d4"
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuietType/Models/Qwen3-0.6B")
    public struct Asset: Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }
    public static let files: [Asset] = [
        Asset(path: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "7b7c483d615cb87d043a593379008d88fa63045f2c72b5b5d613a76b64d44946"),
        Asset(path: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/coremldata.bin", size: 982, sha256: "45fb72a3e2f9740586c89f894407c3546920d7f37ffeef2ec49683f40a7437b6"),
        Asset(path: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/metadata.json", size: 10264, sha256: "61b7de21166fc406bb3c575f6c243d5e66bf24438396d216379a7db5a0e577a8"),
        Asset(path: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/model.mil", size: 2010948, sha256: "c0c80e30e883c65722d55c36b341e2a6356bccedc36b513586ca2e3e2279a234"),
        Asset(path: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/weights/weight.bin", size: 355892992, sha256: "10580536ae3e0846a5316fdda40ec92d4d9feb65c7599110203ba910da2963d6"),
        Asset(path: "qwen_embeddings.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d196be300bb824f90c84ef6bfe4f0a1beb6b5286bf20aef9c5f5f0f5939912c1"),
        Asset(path: "qwen_embeddings.mlmodelc/coremldata.bin", size: 500, sha256: "a3466a99c47ce9f51bb02899445bfcbc8091d9bc0396c9130b5af0da7a7d14fb"),
        Asset(path: "qwen_embeddings.mlmodelc/metadata.json", size: 1846, sha256: "8beaf21e1d7f10cb6e4900a100cc1645498febb1c2dc9aa2f3e2d1ee72332882"),
        Asset(path: "qwen_embeddings.mlmodelc/model.mil", size: 1509, sha256: "6cee82de47669b5a1ced9d1fbace2210226af4d98f9c2df1e55d8ff32cb9b7b8"),
        Asset(path: "qwen_embeddings.mlmodelc/weights/weight.bin", size: 311165056, sha256: "27934f1e8c1d2ce39d0f7c15d7117297794a24e5fd30f42f472d5f123834f532"),
        Asset(path: "qwen_lm_head_lut6.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "9e414bc0050985c1d047c64a2c40f68a1f6b4200b26106e06c6499d9dfd82c6b"),
        Asset(path: "qwen_lm_head_lut6.mlmodelc/coremldata.bin", size: 897, sha256: "5418b075886c44c4f26d73a56700412fc248a8947d2679ce9b3ecf866ec8757b"),
        Asset(path: "qwen_lm_head_lut6.mlmodelc/metadata.json", size: 6553, sha256: "86e507aa54c1cbccf1859926e43816d0ede9bbb08c38fa999f9df5e929c952c0"),
        Asset(path: "qwen_lm_head_lut6.mlmodelc/model.mil", size: 30442, sha256: "5321a3da7875c7d60696ee1be1b13cfde7875e7bd5a05f24c735e718e47cbe07"),
        Asset(path: "qwen_lm_head_lut6.mlmodelc/weights/weight.bin", size: 119119936, sha256: "67c24722deb60c3cba93270807f7404f8022de9ea1010b5686787bed4325f5c4"),
        Asset(path: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        Asset(path: "tokenizer_config.json", size: 8311, sha256: "5fdfe1416aaa323832d52c5bd8624a6e9bba3e9acc6ca8104f017abc775e2368"),
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
