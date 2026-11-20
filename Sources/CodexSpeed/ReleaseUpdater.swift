import AppKit
import CryptoKit
import Foundation

struct DownloadedUpdate: Equatable, Sendable {
    let version: ReleaseVersion
    let page: URL
    let archive: URL
    let integrity: ArchiveIntegrity
}

struct ArchiveIntegrity: Equatable, Sendable {
    let size: Int
    let digest: String

    func matches(_ file: URL) throws -> Bool {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == size else {
            return false
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)" == digest
    }
}

@MainActor
final class ReleaseUpdater {
    enum Status {
        case idle, checking, unpublished, current, failed
        case available(version: ReleaseVersion, page: URL, downloadFailed: Bool)
        case downloading(ReleaseVersion)
        case ready(DownloadedUpdate, failure: String? = nil)
        case installing(ReleaseVersion)
        case recoveryFailed(DownloadedUpdate, backup: URL)

        var message: String? {
            switch self {
            case .idle: nil
            case .checking: "正在检查更新…"
            case .unpublished: "暂时没有已发布版本。"
            case .current: "当前没有可用更新。"
            case .failed: "检查更新失败，可重新检查。"
            case let .available(version, _, downloadFailed):
                downloadFailed ? "无法下载或校验 \(version.text)。" : "新版本 \(version.text) 暂无兼容的安装包。"
            case let .downloading(version): "正在下载 \(version.text)…"
            case let .ready(update, failure): failure ?? "已下载并校验 \(update.version.text)"
            case let .installing(version): "正在安装 \(version.text)…"
            case .recoveryFailed: "新版无法启动，原应用保存在备份中。"
            }
        }

        var canCheck: Bool {
            switch self {
            case .checking, .downloading, .installing, .recoveryFailed: false
            default: true
            }
        }
    }

    private let source = GitHubReleaseSource()
    private var automaticTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private(set) var status: Status = .idle

    var isInstalling: Bool {
        if case .installing = status { return true }
        return false
    }

    deinit {
        automaticTask?.cancel()
        manualTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (automaticTask != nil) else { return }
        if enabled {
            automaticTask = Task { [weak self] in
                while !Task.isCancelled {
                    if self?.status.canCheck == true { await self?.checkForUpdate() }
                    try? await Task.sleep(for: .seconds(6 * 60 * 60))
                }
            }
        } else {
            automaticTask?.cancel()
            automaticTask = nil
            // 手动发起的检查和已下载的更新仍可继续使用。
            if manualTask == nil {
                switch status {
                case .checking, .downloading: status = .idle
                default: break
                }
            }
        }
    }

    func checkNow() {
        guard manualTask == nil, status.canCheck else { return }
        status = .checking
        manualTask = Task { [weak self] in
            await self?.checkForUpdate()
            self?.manualTask = nil
        }
    }

    func stop() {
        setEnabled(false)
        manualTask?.cancel()
    }

    func install(_ update: DownloadedUpdate) {
        guard case let .ready(current, _) = status, current == update else { return }
        status = .installing(update.version)
        Task {
            do {
                try await AppUpdateInstaller.install(update)
                status = .current
                NSApp.terminate(nil)
            } catch AppUpdateInstaller.Failure.restoreFailed(let backup) {
                status = .recoveryFailed(update, backup: backup)
            } catch let failure as AppUpdateInstaller.Failure {
                status = .ready(update, failure: failure.localizedDescription)
            } catch {
                status = .ready(update, failure: "安装失败，可重试或查看发布页。")
            }
        }
    }

    private func checkForUpdate() async {
        guard !Task.isCancelled else { return }
        status = .checking
        guard let installedTag = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let installed = ReleaseVersion(installedTag) else {
            status = .failed
            return
        }

        do {
            let latest = try await source.latestRelease()
            try Task.checkCancellation()
            guard let latest else {
                status = .unpublished
                return
            }
            guard let version = ReleaseVersion(latest.tag) else {
                status = .failed
                return
            }
            guard installed < version else {
                status = .current
                return
            }

            do {
                let candidate = try await source.compatibleAsset(tag: latest.tag, version: version.text)
                try Task.checkCancellation()
                guard let candidate else {
                    status = .available(version: version, page: latest.page, downloadFailed: false)
                    return
                }

                status = .downloading(version)
                let archive = try await source.download(candidate.name, integrity: candidate.integrity, tag: latest.tag)
                try Task.checkCancellation()
                status = .ready(DownloadedUpdate(version: version, page: latest.page, archive: archive, integrity: candidate.integrity))
            } catch {
                if !Task.isCancelled { status = .available(version: version, page: latest.page, downloadFailed: true) }
            }
        } catch {
            if !Task.isCancelled { status = .failed }
        }
    }
}

struct ReleaseVersion: Comparable, Sendable {
    let parts: [Int]
    var text: String { parts.map(String.init).joined(separator: ".") }

    init?(_ tag: String) {
        let version = tag.first?.lowercased() == "v" ? tag.dropFirst() : tag[...]
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, version.allSatisfy({ $0 == "." || $0.isNumber }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

private struct GitHubReleaseSource {
    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let digest: String?

        var integrity: ArchiveIntegrity? {
            guard state == "uploaded", size > 0,
                  let digest = digest?.lowercased(), digest.hasPrefix("sha256:") else { return nil }
            let hash = digest.dropFirst(7)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return ArchiveIntegrity(size: size, digest: digest)
        }
    }

    private struct Release: Decodable {
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private enum FetchError: Error { case invalidResponse, invalidArchive }

    private static let releasesPage = URL(string: "https://github.com/yqstart/codex-speed/releases")!
    private static let releasesAPI = URL(string: "https://api.github.com/repos/yqstart/codex-speed/releases")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func latestRelease() async throws -> (page: URL, tag: String)? {
        // 通过 GitHub 的正式版入口解析标签，只在发现新版时查询附件接口。
        var request = URLRequest(url: Self.releasesPage.appendingPathComponent("latest"))
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let page = response.url,
              page.scheme == "https", page.host == Self.releasesPage.host else { throw FetchError.invalidResponse }
        let releasePath = Self.releasesPage.pathComponents
        let path = page.pathComponents
        if path == releasePath { return nil }
        guard Array(path.dropLast(2)) == releasePath, path.dropLast().last == "tag", let tag = path.last else {
            throw FetchError.invalidResponse
        }
        return (page, tag)
    }

    func compatibleAsset(tag: String, version: String) async throws -> (name: String, integrity: ArchiveIntegrity)? {
        let endpoint = Self.releasesAPI.appendingPathComponent("tags").appendingPathComponent(tag)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.invalidResponse }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let names = ["Codex-Speed-\(version)-\(architecture).zip", "Codex-Speed-\(version)-universal.zip"]
        for name in names {
            if let integrity = release.assets.first(where: { $0.name == name })?.integrity {
                return (name, integrity)
            }
        }
        return nil
    }

    func download(_ name: String, integrity: ArchiveIntegrity, tag: String) async throws -> URL {
        let files = FileManager.default
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appCaches = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.codex-speed", isDirectory: true)
        let directory = appCaches.appendingPathComponent("Updates", isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        if (try? integrity.matches(destination)) == true { return destination }
        try Task.checkCancellation()

        let url = Self.releasesPage.appendingPathComponent("download").appendingPathComponent(tag)
            .appendingPathComponent(name)
        let (temporary, response) = try await session.download(from: url)
        defer { try? files.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https" else {
            throw FetchError.invalidResponse
        }
        guard try integrity.matches(temporary) else { throw FetchError.invalidArchive }
        try Task.checkCancellation()

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
        return destination
    }

}
