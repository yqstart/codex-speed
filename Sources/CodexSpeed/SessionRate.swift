import Foundation

struct RateReading: Equatable, Sendable {
    let value: Int
    let estimated: Bool

    var displayValue: String { (estimated ? "≈" : "") + String(value) }
}

struct SessionReading {
    let reading: RateReading?
    let observedAt: Date
    let isDesktop: Bool
}

struct SessionRate {
    private struct Sample {
        let tokens: Double
        let seconds: TimeInterval
        let recordedAt: Date
        let model: String?
    }

    private(set) var id: String?
    private(set) var model: String?
    private var isDesktop = false
    private(set) var isSubagent = false
    private var createdAt: Date?
    private var lastActivity: Date?
    private var turnOpen = false
    private var sawOutput = false
    private var requestStart: Date?
    private var continuationStart: Date?
    private var pendingTools = Set<String>()
    private var toolCallAt: Date?
    private var toolResultAt: Date?
    private var hasModernUsage = false
    private var responseIDs: [String] = []
    private var previousTotal: TokenCounts?
    private var samples: [Sample] = []

    mutating func ingest(_ record: LogRecord) {
        let time = record.time
        if case let .metadata(id, desktop, subagent) = record.event {
            guard createdAt == nil else { return }
            createdAt = time
            self.id = id
            isDesktop = desktop
            isSubagent = subagent
            return
        }
        if isSubagent || (createdAt?.timeIntervalSince(time) ?? 0) > 2 { return }

        switch record.event {
        case .metadata:
            break
        case let .model(name):
            model = name
        case .turnStarted:
            startTurn(at: time)
        case .userInput:
            if !turnOpen { startTurn(at: time) }
        case .turnEnded:
            resetRequest()
            turnOpen = false
        case .modelOutput:
            // 新输出也能让从日志中途开始采样的会话进入生成状态。
            if requestStart == nil && !pendingTools.isEmpty { pendingTools.removeAll() }
            if let nextStart = toolResultAt, pendingTools.isEmpty {
                requestStart = nextStart
                toolCallAt = nil
                toolResultAt = nil
            }
            requestStart = requestStart ?? continuationStart
            sawOutput = true
            turnOpen = true
            lastActivity = time
        case .toolCall(let id):
            pendingTools.insert(id)
            toolCallAt = time
            turnOpen = true
            lastActivity = time
        case .toolResult(let id):
            pendingTools.remove(id)
            guard pendingTools.isEmpty else { return }
            // 旧日志可能先写工具结果，再写上一请求的用量。
            if requestStart != nil && toolCallAt != nil {
                toolResultAt = time
            } else {
                requestStart = time
            }
            turnOpen = true
            lastActivity = time
        case let .modernUsage(id, tokens):
            hasModernUsage = true
            if let id {
                guard !responseIDs.contains(id) else { return }
                responseIDs.append(id)
                if responseIDs.count > 64 { responseIDs.removeFirst() }
            }
            finishRequest(tokens: tokens, end: time, recordedAt: time)
        case let .legacyUsage(total, last):
            guard !hasModernUsage, total.output >= 0 else { return }
            let previous = previousTotal
            previousTotal = total
            var tokens = last?.output
            if let previous {
                let counter = total.total ?? total.output
                let previousCounter = previous.total ?? previous.output
                guard counter != previousCounter else { return }
                if counter > previousCounter, total.output >= previous.output {
                    tokens = total.output - previous.output
                }
            }
            finishRequest(tokens: tokens, end: toolCallAt ?? time, recordedAt: time)
        }
    }

    func reading(at now: Date) -> SessionReading? {
        guard !isSubagent, let lastActivity else { return nil }
        let activityAge = now.timeIntervalSince(lastActivity)
        guard (-2...300).contains(activityAge) else { return nil }
        let matchingSamples = samples.filter { $0.model == model }

        if let sample = matchingSamples.last, (-2...3).contains(now.timeIntervalSince(sample.recordedAt)) {
            return SessionReading(
                reading: makeReading(tokens: sample.tokens, seconds: sample.seconds, estimated: false),
                observedAt: lastActivity,
                isDesktop: isDesktop
            )
        }
        guard turnOpen else { return nil }
        var reading: RateReading?
        if activityAge <= 120, pendingTools.isEmpty, requestStart != nil || toolResultAt != nil || sawOutput {
            let recent = matchingSamples.filter { (-2...600).contains(now.timeIntervalSince($0.recordedAt)) }
            reading = makeReading(tokens: recent.reduce(0) { $0 + $1.tokens }, seconds: recent.reduce(0) { $0 + $1.seconds }, estimated: true)
        }
        return SessionReading(
            reading: reading,
            observedAt: lastActivity,
            isDesktop: isDesktop
        )
    }

    private mutating func startTurn(at time: Date) {
        resetRequest()
        turnOpen = true
        requestStart = time
        lastActivity = time
    }

    private mutating func resetRequest() {
        sawOutput = false
        requestStart = nil
        continuationStart = nil
        pendingTools.removeAll()
        toolCallAt = nil
        toolResultAt = nil
    }

    private mutating func finishRequest(tokens: Int?, end: Date, recordedAt: Date) {
        if let requestStart, let tokens, tokens > 0 {
            let seconds = end.timeIntervalSince(requestStart)
            if (0.05...900).contains(seconds) {
                samples.append(Sample(tokens: Double(tokens), seconds: seconds, recordedAt: recordedAt, model: model))
                if samples.count > 3 { samples.removeFirst() }
            }
        }
        lastActivity = recordedAt
        requestStart = toolResultAt
        continuationStart = toolCallAt == nil ? end : nil
        toolCallAt = nil
        toolResultAt = nil
        sawOutput = false
    }

    private func makeReading(tokens: Double, seconds: TimeInterval, estimated: Bool) -> RateReading? {
        guard seconds > 0, let value = Int(exactly: (tokens / seconds).rounded()) else { return nil }
        return RateReading(value: value, estimated: estimated)
    }
}
