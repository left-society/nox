import Foundation
import QuartzCore

struct PerformanceFrameStats {
    static let sixtyFPSBudgetMs = 1000.0 / 60.0

    private(set) var sampleCount = 0
    private(set) var totalMs: Double = 0
    private(set) var worstMs: Double = 0
    private(set) var over60BudgetCount = 0
    private(set) var over20MsCount = 0
    private(set) var over33MsCount = 0
    private(set) var over50MsCount = 0
    private(set) var over100MsCount = 0

    var averageMs: Double {
        guard sampleCount > 0 else { return 0 }
        return totalMs / Double(sampleCount)
    }

    mutating func record(deltaMs: Double) {
        guard deltaMs.isFinite, deltaMs >= 0 else { return }

        sampleCount += 1
        totalMs += deltaMs
        worstMs = max(worstMs, deltaMs)

        if deltaMs > Self.sixtyFPSBudgetMs { over60BudgetCount += 1 }
        if deltaMs > 20 { over20MsCount += 1 }
        if deltaMs > 33 { over33MsCount += 1 }
        if deltaMs > 50 { over50MsCount += 1 }
        if deltaMs > 100 { over100MsCount += 1 }
    }

    mutating func snapshotAndReset() -> PerformanceFrameStatsSnapshot {
        let snapshot = PerformanceFrameStatsSnapshot(
            sampleCount: sampleCount,
            averageMs: averageMs,
            worstMs: worstMs,
            over60BudgetCount: over60BudgetCount,
            over20MsCount: over20MsCount,
            over33MsCount: over33MsCount,
            over50MsCount: over50MsCount,
            over100MsCount: over100MsCount
        )
        self = PerformanceFrameStats()
        return snapshot
    }
}

struct PerformanceFrameStatsSnapshot: Equatable {
    let sampleCount: Int
    let averageMs: Double
    let worstMs: Double
    let over60BudgetCount: Int
    let over20MsCount: Int
    let over33MsCount: Int
    let over50MsCount: Int
    let over100MsCount: Int

    var isEmpty: Bool { sampleCount == 0 }
}

@MainActor
final class PerformanceProbe {
    static let shared = PerformanceProbe()

    private let sampleInterval: TimeInterval = 1.0 / 60.0
    private let summaryInterval: CFTimeInterval = 1.0
    private let timestampFormatter: ISO8601DateFormatter

    private var timer: Timer?
    private var lastTickTime: CFTimeInterval?
    private var summaryStartTime: CFTimeInterval?
    private var stats = PerformanceFrameStats()
    private var fileHandle: FileHandle?
    private var logURL: URL?
    private var contextProvider: (() -> String)?
    private var activeProvider: (() -> Bool)?

    private init() {
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func setContextProvider(_ provider: @escaping () -> String) {
        contextProvider = provider
    }

    func setActiveProvider(_ provider: @escaping () -> Bool) {
        activeProvider = provider
    }

    func start() {
        guard timer == nil else { return }
        guard prepareLogFile() else { return }

        let now = CACurrentMediaTime()
        lastTickTime = now
        summaryStartTime = now

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { _ in
            Task { @MainActor in
                PerformanceProbe.shared.handleTimerFire()
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        mark("SESSION_START", metadata: [
            "sampleHz": "60",
            "budgetMs": formatMs(PerformanceFrameStats.sixtyFPSBudgetMs)
        ])

        if let logURL {
            NSLog("nox: performance probe writing to %@", logURL.path)
        }
    }

    func stop() {
        mark("SESSION_STOP")
        timer?.invalidate()
        timer = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    func mark(_ name: String, metadata: [String: String] = [:]) {
        var fields = [field("name", name)]
        fields.append(contentsOf: metadataFields(metadata))
        fields.append(field("context", contextProvider?() ?? "none"))
        writeEvent("MARK", fields: fields)
    }

    func currentLogURL() -> URL? {
        logURL
    }

    private func handleTimerFire() {
        let now = CACurrentMediaTime()
        guard let lastTickTime else {
            self.lastTickTime = now
            summaryStartTime = now
            return
        }

        let deltaMs = (now - lastTickTime) * 1000
        self.lastTickTime = now
        stats.record(deltaMs: deltaMs)
        let active = activeProvider?() ?? true
        let context = contextProvider?() ?? "none"

        if deltaMs > spikeThreshold(active: active) {
            writeEvent("SPIKE", fields: [
                field("deltaMs", formatMs(deltaMs)),
                field("severity", severity(for: deltaMs)),
                field("active", active),
                field("context", context)
            ])
        }

        let summaryStart = summaryStartTime ?? now
        if now - summaryStart >= summaryInterval {
            let snapshot = stats.snapshotAndReset()
            summaryStartTime = now
            guard !snapshot.isEmpty else { return }
            writeEvent("SUMMARY", fields: [
                field("samples", snapshot.sampleCount),
                field("avgMs", formatMs(snapshot.averageMs)),
                field("worstMs", formatMs(snapshot.worstMs)),
                field("over16", snapshot.over60BudgetCount),
                field("over20", snapshot.over20MsCount),
                field("over33", snapshot.over33MsCount),
                field("over50", snapshot.over50MsCount),
                field("over100", snapshot.over100MsCount),
                field("active", active),
                field("context", context)
            ])
        }
    }

    private func prepareLogFile() -> Bool {
        do {
            let logsDirectory = try performanceLogDirectory()
            let filename = "performance-\(fileTimestamp()).log"
            let url = logsDirectory.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: url)
            logURL = url
            return true
        } catch {
            NSLog("nox: performance probe failed to open log: %@", error.localizedDescription)
            return false
        }
    }

    private func performanceLogDirectory() throws -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let logs = library.appendingPathComponent("Logs/nox", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    private func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private func writeEvent(_ event: String, fields: [String]) {
        guard let fileHandle else { return }
        let timestamp = timestampFormatter.string(from: Date())
        let line = ([timestamp, event] + fields).joined(separator: " ") + "\n"
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    private func metadataFields(_ metadata: [String: String]) -> [String] {
        metadata.keys.sorted().map { key in
            field(key, metadata[key] ?? "")
        }
    }

    private func field(_ key: String, _ value: CustomStringConvertible) -> String {
        "\(key)=\(encoded(value.description))"
    }

    private func encoded(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: "_")
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func severity(for deltaMs: Double) -> String {
        if deltaMs > 100 { return "freeze" }
        if deltaMs > 50 { return "visible-jank" }
        if deltaMs > 33 { return "multi-frame-drop" }
        return "missed-60fps"
    }

    private func spikeThreshold(active: Bool) -> Double {
        active ? 20 : 50
    }
}
