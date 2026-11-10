import AppKit
import CryptoKit
import Observation
import QuietTypeCore
import Security

/// Self-update from GitHub Releases: the newest release's DMG replaces this app bundle.
/// A build is installed only when its checksum matches the release and it is signed by
/// the same developer as the running app, so macOS keeps the granted permissions.
@MainActor @Observable
final class Updater {
    static let repository = "lanceqqe/QuietType"
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var status = ""
    var busy = false
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate") }
    }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored var log: (String) -> Void = { _ in }

    init() { automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }

    /// One check at launch and one a day after that.
    func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.automatic == true { await self?.check(install: true) }
                guard (try? await Task.sleep(for: .seconds(24 * 3600))) != nil else { return }
            }
        }
    }

    func check(install: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            status = "Проверка обновлений…"
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard AppVersion.isNewer(version, than: Self.currentVersion) else {
                status = "Установлена последняя версия \(Self.currentVersion)"
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { throw Failure.unavailable }
            guard install else { status = "Доступна версия \(version)"; return }
            status = "Загрузка версии \(version)…"
            log("update: downloading \(version)")
            let (file, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            defer { try? FileManager.default.removeItem(at: file) }
            let expected = String(digest.dropFirst(7))
            status = "Установка версии \(version)…"
            try await Task.detached { try Self.install(dmg: file, sha256: expected) }.value
            log("update: installed \(version), relaunching")
            relaunch()
        } catch {
            status = "Обновление не удалось: \(error.localizedDescription)"
            log("update failed: \(error.localizedDescription)")
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        let tag_name: String
        let assets: [Asset]
    }

    enum Failure: LocalizedError {
        case unavailable, checksum, signature, location, tool(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "не удалось получить релиз с GitHub"
            case .checksum: "контрольная сумма файла не совпала"
            case .signature: "подпись новой версии не совпадает с установленной"
            case .location: "перенесите QuietType в «Программы» и запустите оттуда"
            case .tool(let message): message
            }
        }
    }

    private nonisolated static func install(dmg: URL, sha256: String) throws {
        let fm = FileManager.default
        let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw Failure.checksum }
        let bundle = Bundle.main.bundleURL
        // A quarantined app run from Downloads or the disk image lives on a read-only copy.
        guard bundle.pathExtension == "app", !bundle.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw Failure.location }
        let mount = fm.temporaryDirectory.appendingPathComponent("QuietType-update-" + UUID().uuidString)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let fresh = mount.appendingPathComponent("QuietType.app")
        try verifySignature(of: fresh)
        // Stage next to the installed app (same volume), then swap in one step.
        let staged = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
            .appendingPathComponent("QuietType.app")
        try run("/usr/bin/ditto", [fresh.path, staged.path])
        _ = try fm.replaceItemAt(bundle, withItemAt: staged)
    }

    /// The new bundle must be intact and satisfy the running app's own designated requirement.
    private nonisolated static func verifySignature(of app: URL) throws {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
                                         requirement) == errSecSuccess
        else { throw Failure.signature }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.tool("\(URL(fileURLWithPath: tool).lastPathComponent) завершился с кодом \(process.terminationStatus)")
        }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Start the new copy once this process is gone.
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                             Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
