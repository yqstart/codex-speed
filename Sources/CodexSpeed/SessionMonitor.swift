import Foundation

struct SessionSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let model: String?
    let reading: RateReading?
}

final class SessionMonitor {
    private let queue = DispatchQueue(label: "local.codex-speed.sessions", qos: .utility)
    private let report: @MainActor ([SessionSnapshot]) -> Void
    private let decoder = LogRecordDecoder()
    private let root: URL
    private var titleIndex: SessionTitleIndex
    private var timer: DispatchSourceTimer?
    private var sessions: [URL: SessionTail] = [:]
    private var nextScan = Date.distantPast
    private var lastSnapshot: [SessionSnapshot] = []

    init(report: @escaping @MainActor ([SessionSnapshot]) -> Void) {
        self.report = report
        let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let codexHome = configuredHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        titleIndex = SessionTitleIndex(url: codexHome.appendingPathComponent("session_index.jsonl"))
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let now = Date()
        if now >= nextScan {
            discoverSessions(at: now)
            titleIndex.refresh()
            nextScan = now.addingTimeInterval(2)
        }

        var candidates: [(activity: SessionReading, snapshot: SessionSnapshot)] = []
        for (url, session) in sessions {
            session.readFile(url, decoder: decoder)
            guard let activity = session.rate.reading(at: now) else { continue }
            let knownID = session.rate.id
            let title = knownID.flatMap { titleIndex.titles[$0] }
            let suffix = (knownID ?? url.deletingPathExtension().lastPathComponent).suffix(6)
            let snapshot = SessionSnapshot(
                id: knownID ?? url.path,
                title: title ?? "会话 \(suffix)",
                model: session.rate.model,
                reading: activity.reading
            )
            candidates.append((activity, snapshot))
        }

        candidates.sort { first, second in
            if first.activity.isDesktop != second.activity.isDesktop { return first.activity.isDesktop }
            if first.activity.observedAt != second.activity.observedAt { return first.activity.observedAt > second.activity.observedAt }
            return first.snapshot.id < second.snapshot.id
        }
        var seen = Set<String>()
        let snapshot = candidates.compactMap { seen.insert($0.snapshot.id).inserted ? $0.snapshot : nil }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        DispatchQueue.main.async { [report] in report(snapshot) }
    }

    private func discoverSessions(at now: Date) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let items = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            sessions.removeAll()
            return
        }

        let cutoff = now.addingTimeInterval(-1200)
        let recent: [(url: URL, modified: Date)] = items.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified > cutoff else { return nil }
            return (url, modified)
        }
        let newest = recent.sorted { $0.modified > $1.modified }.prefix(16)
        sessions = Dictionary(uniqueKeysWithValues: newest.map { ($0.url, sessions[$0.url] ?? SessionTail()) })
    }
}

private struct SessionTitleIndex {
    private struct Entry: Decodable {
        let id: String
        let title: String

        enum CodingKeys: String, CodingKey {
            case id
            case title = "thread_name"
        }
    }

    let url: URL
    private var modified: Date?
    private var size: UInt64?
    private(set) var titles: [String: String] = [:]

    init(url: URL) {
        self.url = url
    }

    mutating func refresh() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let date = attributes[.modificationDate] as? Date,
              let bytes = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        guard modified != date || size != bytes, let contents = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        var updated: [String: String] = [:]
        for line in contents.split(separator: 10) {
            guard let entry = try? decoder.decode(Entry.self, from: line) else { continue }
            let title = entry.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            updated[entry.id] = title.isEmpty ? nil : title
        }
        titles = updated
        modified = date
        size = bytes
    }
}

private final class SessionTail {
    private static let readLimit = 2 * 1024 * 1024
    private static let chunkSize = 64 * 1024
    private var identity: UInt64?
    private var modifiedAt: Date?
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var skipLine = false
    private(set) var rate = SessionRate()

    func readFile(_ url: URL, decoder: LogRecordDecoder) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return }
        let reset = identity != fileID || size < offset || (size == offset && modifiedAt != modified)
        guard reset || (size > offset && !rate.isSubagent) else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            if reset {
                try rewind(handle, size: size, decoder: decoder)
                identity = fileID
            }
            modifiedAt = modified
            guard !rate.isSubagent else { return }
            try handle.seek(toOffset: offset)
            let end = min(size, offset + UInt64(Self.readLimit))
            while offset < end {
                let count = min(Self.chunkSize, Int(end - offset))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                consume(chunk, decoder: decoder)
            }
        } catch {
            // 写入方可能正在替换日志，下一次轮询继续检查。
        }
    }

    private func rewind(_ handle: FileHandle, size: UInt64, decoder: LogRecordDecoder) throws {
        rate = SessionRate()
        buffer.removeAll(keepingCapacity: false)
        let limit = UInt64(Self.readLimit)
        offset = size > limit ? size - limit : 0
        skipLine = false
        guard offset > 0 else { return }

        // 会话来源只在开头，速率预热只需要尾部记录。
        if let header = try handle.read(upToCount: Self.chunkSize), let lineEnd = header.firstIndex(of: 10),
           let record = decoder.decode(header.prefix(upTo: lineEnd)) {
            rate.ingest(record)
        }
        try handle.seek(toOffset: offset - 1)
        skipLine = try handle.read(upToCount: 1)?.first != 10
    }

    private func consume(_ chunk: Data, decoder: LogRecordDecoder) {
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        while let lineEnd = buffer[lineStart...].firstIndex(of: 10) {
            if !skipLine && lineEnd - lineStart <= Self.readLimit,
               let record = decoder.decode(buffer[lineStart..<lineEnd]) {
                rate.ingest(record)
            }
            skipLine = false
            lineStart = lineEnd + 1
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)
        if buffer.count > Self.readLimit {
            buffer.removeAll(keepingCapacity: false)
            skipLine = true
        }
    }
}
