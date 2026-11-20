import CryptoKit
import Foundation

@MainActor
final class ReleaseUpdater {
    enum Status: Equatable {
        case disabled, checking, unpublished, current, failed
        case available(version: String, page: URL)
        case downloading(version: String)
        case downloaded(version: String, archive: URL)

        var message: String {
            switch self {
            case .disabled: "开启后会检查并下载正式版更新。"
            case .checking: "正在检查更新…"
            case .unpublished: "暂时没有已发布版本。"
            case .current: "当前没有可用更新。"
            case .failed: "暂时无法检查更新，稍后会重试。"
            case let .available(version, _): "发现新版本 \(version)"
            case let .downloading(version): "正在下载 \(version)…"
            case let .downloaded(version, _): "已下载并校验 \(version)"
            }
        }
    }

    private let source = GitHubReleaseSource()
    private let onStatus: (Status) -> Void
    private var task: Task<Void, Never>?
    private(set) var status: Status = .disabled {
        didSet {
            if status != oldValue { onStatus(status) }
        }
    }

    init(onStatus: @escaping (Status) -> Void) {
        self.onStatus = onStatus
    }

    deinit { task?.cancel() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (task != nil) else { return }
        if enabled {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.checkForUpdate()
                    try? await Task.sleep(for: .seconds(6 * 60 * 60))
                }
            }
        } else {
            task?.cancel()
            task = nil
            status = .disabled
        }
    }

    private func checkForUpdate() async {
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
            guard let version = ReleaseVersion(latest.tag), installed < version else {
                status = .current
                return
            }

            let available = Status.available(version: version.text, page: latest.page)
            let candidate = try? await source.compatibleAsset(tag: latest.tag, version: version.text)
            try Task.checkCancellation()
            guard let asset = candidate else {
                status = available
                return
            }

            status = .downloading(version: version.text)
            let archive = try? await source.download(asset, tag: latest.tag)
            try Task.checkCancellation()
            status = archive.map { .downloaded(version: version.text, archive: $0) } ?? available
        } catch {
            if !Task.isCancelled { status = .failed }
        }
    }
}

private struct ReleaseVersion: Comparable {
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
    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let digest: String?

        var canVerify: Bool {
            guard state == "uploaded", size > 0, let digest, digest.hasPrefix("sha256:") else { return false }
            let hash = digest.dropFirst(7)
            return hash.count == 64 && hash.allSatisfy(\.isHexDigit)
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

    func compatibleAsset(tag: String, version: String) async throws -> Asset? {
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
            if let asset = release.assets.first(where: { $0.name == name && $0.canVerify }) { return asset }
        }
        return nil
    }

    func download(_ asset: Asset, tag: String) async throws -> URL {
        let files = FileManager.default
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appCaches = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.codex-speed", isDirectory: true)
        let directory = appCaches.appendingPathComponent("Updates", isDirectory: true)
        let destination = directory.appendingPathComponent(asset.name)
        if (try? matches(destination, asset: asset)) == true { return destination }
        try Task.checkCancellation()

        let url = Self.releasesPage.appendingPathComponent("download").appendingPathComponent(tag)
            .appendingPathComponent(asset.name)
        let (temporary, response) = try await session.download(from: url)
        defer { try? files.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https" else {
            throw FetchError.invalidResponse
        }
        guard try matches(temporary, asset: asset) else { throw FetchError.invalidArchive }
        try Task.checkCancellation()

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    private func matches(_ file: URL, asset: Asset) throws -> Bool {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == asset.size else {
            return false
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)" == asset.digest?.lowercased()
    }
}
