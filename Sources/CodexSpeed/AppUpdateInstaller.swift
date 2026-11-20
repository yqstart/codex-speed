import AppKit
import Darwin
import Foundation
import Security

enum AppUpdateInstaller {
    enum Failure: LocalizedError {
        case location, busy, installedAppChanged, archiveChanged, invalidArchive, invalidApplication
        case replacementFailed, launchFailed, restoreFailed(URL)

        var errorDescription: String? {
            switch self {
            case .location: "应用位于无法替换的位置，请移到可写的「应用程序」文件夹后重试。"
            case .busy: "另一实例正在安装更新，稍后可重试。"
            case .installedAppChanged: "磁盘上的应用已更改，请重新打开后再更新。"
            case .archiveChanged: "安装包校验失败，请重新检查更新。"
            case .invalidArchive: "无法解压安装包，可查看发布页。"
            case .invalidApplication: "安装包中的应用标识、版本或签名校验失败。"
            case .replacementFailed: "无法替换现有应用，可查看发布页手动安装。"
            case .launchFailed: "新版无法启动，已恢复原应用。"
            case .restoreFailed: "新版无法启动，原应用保存在备份中。"
            }
        }
    }

    private struct InstalledApp: Sendable {
        let url: URL
        let identifier: String
        let version: ReleaseVersion
        let executable: String

        init(bundle: Bundle) throws {
            url = bundle.bundleURL.resolvingSymlinksInPath()
            guard url.pathExtension.lowercased() == "app",
                  let identifier = bundle.bundleIdentifier,
                  let tag = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let version = ReleaseVersion(tag),
                  let executable = bundle.executableURL?.lastPathComponent else {
                throw Failure.location
            }
            self.identifier = identifier
            self.version = version
            self.executable = executable
        }
    }

    private struct DirectoryIdentity: Equatable, Sendable {
        let volume: UInt64
        let file: UInt64

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            volume = device.uint64Value
            file = inode.uint64Value
        }
    }

    private struct Installation: Sendable {
        let destination: URL
        let stagedApp: URL
        let directory: URL
        let originalIdentity: DirectoryIdentity
        let stagedIdentity: DirectoryIdentity
        let lock: Int32

        func swap(restoring: Bool = false) throws {
            let current = restoring ? stagedIdentity : originalIdentity
            let replacement = restoring ? originalIdentity : stagedIdentity
            guard DirectoryIdentity(destination) == current,
                  DirectoryIdentity(stagedApp) == replacement else { throw Failure.installedAppChanged }

            // 两个应用包同时交换位置，解压文件和原应用始终位于同一卷。
            let result = destination.withUnsafeFileSystemRepresentation { installedPath in
                stagedApp.withUnsafeFileSystemRepresentation { stagedPath in
                    renameatx_np(AT_FDCWD, installedPath, AT_FDCWD, stagedPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw Failure.replacementFailed }
        }

        func finish(keepingBackup: Bool) {
            if !keepingBackup { try? FileManager.default.removeItem(at: directory) }
            close(lock)
        }
    }

    @MainActor
    static func install(_ update: DownloadedUpdate) async throws {
        let installed = try InstalledApp(bundle: .main)
        let installation = try await Task.detached(priority: .utility) {
            try prepare(update, replacing: installed)
        }.value
        var keepBackup = false
        defer { installation.finish(keepingBackup: keepBackup) }

        try installation.swap()
        do {
            try await launch(installed, version: update.version)
        } catch {
            do {
                try installation.swap(restoring: true)
            } catch {
                keepBackup = true
                throw Failure.restoreFailed(installation.stagedApp)
            }
            throw Failure.launchFailed
        }
    }

    private static func prepare(_ update: DownloadedUpdate, replacing installed: InstalledApp) throws -> Installation {
        let files = FileManager.default
        let parent = installed.url.deletingLastPathComponent()
        let volume = try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard volume?.volumeIsReadOnly != true, files.isWritableFile(atPath: parent.path) else {
            throw Failure.location
        }

        let lockURL = update.archive.deletingLastPathComponent().appendingPathComponent(".installation.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else { throw Failure.replacementFailed }

        let directory = parent.appendingPathComponent(".codex-speed-update-\(UUID().uuidString)", isDirectory: true)
        var directoryCreated = false
        var prepared = false
        defer {
            if !prepared {
                if directoryCreated { try? files.removeItem(at: directory) }
                close(lock)
            }
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }

        guard let originalIdentity = DirectoryIdentity(installed.url),
              let info = try? applicationInfo(installed.url),
              info["CFBundleIdentifier"] as? String == installed.identifier,
              info["CFBundleExecutable"] as? String == installed.executable,
              (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) == installed.version,
              installed.version < update.version else { throw Failure.installedAppChanged }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directoryCreated = true
        } catch {
            throw Failure.location
        }

        let archive = directory.appendingPathComponent("update.zip")
        do {
            try files.copyItem(at: update.archive, to: archive)
            guard try update.integrity.matches(archive) else { throw Failure.archiveChanged }
        } catch {
            throw Failure.archiveChanged
        }

        let expanded = directory.appendingPathComponent("Application", isDirectory: true)
        try extract(archive, into: expanded)
        let stagedApp = expanded.appendingPathComponent("Codex Speed.app", isDirectory: true)
        guard let stagedIdentity = DirectoryIdentity(stagedApp),
              stagedIdentity.volume == originalIdentity.volume,
              let stagedInfo = try? applicationInfo(stagedApp),
              stagedInfo["CFBundlePackageType"] as? String == "APPL",
              stagedInfo["CFBundleIdentifier"] as? String == installed.identifier,
              stagedInfo["CFBundleExecutable"] as? String == installed.executable,
              (stagedInfo["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) == update.version else {
            throw Failure.invalidApplication
        }
        try verifySignature(stagedApp, replacing: installed.url)

        prepared = true
        return Installation(destination: installed.url, stagedApp: stagedApp, directory: directory,
                            originalIdentity: originalIdentity, stagedIdentity: stagedIdentity, lock: lock)
    }

    private static func applicationInfo(_ url: URL) throws -> [String: Any] {
        let file = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: file)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else { throw Failure.invalidApplication }
        return dictionary
    }

    private static func extract(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.invalidArchive
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.invalidArchive }
    }

    private static func verifySignature(_ candidate: URL, replacing installed: URL) throws {
        let code = try staticCode(at: candidate)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Failure.invalidApplication }
        // 已有开发者团队签名时，更新必须由同一团队签署。
        if let team = try teamIdentifier(of: staticCode(at: installed)),
           try teamIdentifier(of: code) != team {
            throw Failure.invalidApplication
        }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.invalidApplication
        }
        return code
    }

    private static func teamIdentifier(of code: SecStaticCode) throws -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw Failure.invalidApplication
        }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    @MainActor
    private static func launch(_ installed: InstalledApp, version: ReleaseVersion) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: installed.url, configuration: configuration)
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier == installed.identifier else { throw Failure.launchFailed }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !app.isFinishedLaunching, !app.isTerminated, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        // macOS 隔离启动时会改变进程的应用包路径，仍须确认启动的是预期版本。
        guard app.isFinishedLaunching, !app.isTerminated, let launched = app.bundleURL,
              let info = try? applicationInfo(launched),
              (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) == version else {
            app.terminate()
            throw Failure.launchFailed
        }
    }
}
