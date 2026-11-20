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
    enum DownloadIssue {
        case metadata, rateLimited, transfer, verification, cache

        func message(for version: ReleaseVersion) -> String {
            switch self {
            case .metadata: "获取 \(version.text) 的安装包信息失败。"
            case .rateLimited: "GitHub 暂时限制更新请求，可稍后重试。"
            case .transfer: "下载 \(version.text) 失败，可重新检查。"
            case .verification: "安装包 \(version.text) 校验失败。"
            case .cache: "无法写入更新缓存。"
            }
        }
    }

    enum Status {
        case idle, checking, unpublished, current, failed
        case available(version: ReleaseVersion, page: URL, issue: DownloadIssue? = nil)
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
            case let .available(version, _, issue):
                issue?.message(for: version) ?? "新版本 \(version.text) 暂无兼容的安装包。"
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
                    status = .available(version: version, page: latest.page)
                    return
                }

                status = .downloading(version)
                let archive = try await source.download(candidate.name, integrity: candidate.integrity, tag: latest.tag)
                try Task.checkCancellation()
                status = .ready(DownloadedUpdate(version: version, page: latest.page, archive: archive, integrity: candidate.integrity))
            } catch {
                guard !Task.isCancelled else { return }
                let issue: DownloadIssue
                switch error {
                case GitHubReleaseSource.FetchError.rateLimited: issue = .rateLimited
                case GitHubReleaseSource.FetchError.invalidArchive: issue = .verification
                case GitHubReleaseSource.FetchError.cacheUnavailable: issue = .cache
                default:
                    if case .downloading = status { issue = .transfer } else { issue = .metadata }
                }
                status = .available(version: version, page: latest.page, issue: issue)
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
        let state: String?
        let size: Int
        let digest: String?

        var integrity: ArchiveIntegrity? {
            guard size > 0, let digest = digest?.lowercased(), digest.hasPrefix("sha256:") else { return nil }
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

    private struct ChecksumManifest: Decodable {
        let assets: [Asset]
    }

    enum FetchError: Error {
        case invalidResponse, httpStatus(Int), rateLimited, invalidArchive, cacheUnavailable
    }

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
        // 发布附件中的清单可直接访问，旧版本附件仍可从 GitHub 接口读取摘要。
        if let manifest = try? await checksumManifest(tag: tag),
           let candidate = compatibleAsset(in: manifest.assets, version: version) {
            return candidate
        }
        try Task.checkCancellation()

        let endpoint = Self.releasesAPI.appendingPathComponent("tags").appendingPathComponent(tag)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data = try await fetchData(request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return compatibleAsset(in: release.assets.filter { $0.state == "uploaded" }, version: version)
    }

    private func checksumManifest(tag: String) async throws -> ChecksumManifest {
        let url = assetURL("Codex-Speed-update.json", tag: tag)
        let data = try await fetchData(URLRequest(url: url))
        return try JSONDecoder().decode(ChecksumManifest.self, from: data)
    }

    private func compatibleAsset(in assets: [Asset], version: String) -> (name: String, integrity: ArchiveIntegrity)? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let names = ["Codex-Speed-\(version)-\(architecture).zip", "Codex-Speed-\(version)-universal.zip"]
        for name in names {
            if let integrity = assets.first(where: { $0.name == name })?.integrity {
                return (name, integrity)
            }
        }
        return nil
    }

    func download(_ name: String, integrity: ArchiveIntegrity, tag: String) async throws -> URL {
        let files = FileManager.default
        guard let caches = try? files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            throw FetchError.cacheUnavailable
        }
        let appCaches = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.codex-speed", isDirectory: true)
        let directory = appCaches.appendingPathComponent("Updates", isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        if (try? integrity.matches(destination)) == true { return destination }
        try Task.checkCancellation()

        let url = assetURL(name, tag: tag)
        let temporary = try await retryingTransientFailure {
            let (temporary, response) = try await session.download(from: url)
            do {
                try validate(response)
                return temporary
            } catch {
                try? files.removeItem(at: temporary)
                throw error
            }
        }
        defer { try? files.removeItem(at: temporary) }
        let verified = (try? integrity.matches(temporary)) == true
        try Task.checkCancellation()
        guard verified else { throw FetchError.invalidArchive }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try files.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw FetchError.cacheUnavailable
        }
        return destination
    }

    private func assetURL(_ name: String, tag: String) -> URL {
        Self.releasesPage.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(name)
    }

    private func fetchData(_ request: URLRequest) async throws -> Data {
        try await retryingTransientFailure {
            let (data, response) = try await session.data(for: request)
            try validate(response)
            return data
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw FetchError.invalidResponse
        }
        let status = response.statusCode
        if status == 429 || (status == 403 && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                                                || response.value(forHTTPHeaderField: "Retry-After") != nil)) {
            throw FetchError.rateLimited
        }
        guard status == 200 else { throw FetchError.httpStatus(status) }
    }

    private func retryingTransientFailure<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            let retryable: Bool
            if case FetchError.httpStatus(let status) = error {
                // 发布后附件信息和下载链接可能短时间尚未同步。
                retryable = status == 404 || status == 408 || (500...599).contains(status)
            } else if let network = error as? URLError {
                retryable = [.timedOut, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost].contains(network.code)
            } else {
                retryable = false
            }
            guard retryable else { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await operation()
        }
    }
}
