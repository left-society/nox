import AppKit
import Foundation
import QuartzCore
import os

struct PerformanceFrameStats {
    static let sixtyFPSBudgetMs = 1000.0 / 60.0

    private(set) var sampleCount = 0
    private(set) var totalMs: Double = 0
    private(set) var worstMs: Double = 0
    private(set) var hitchTimeMs: Double = 0
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
        hitchTimeMs += max(0, deltaMs - Self.sixtyFPSBudgetMs)

        if deltaMs > Self.sixtyFPSBudgetMs { over60BudgetCount += 1 }
        if deltaMs > 20 { over20MsCount += 1 }
        if deltaMs > 33 { over33MsCount += 1 }
        if deltaMs > 50 { over50MsCount += 1 }
        if deltaMs > 100 { over100MsCount += 1 }
    }

    func hitchRatioMsPerSecond(overDuration duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return hitchTimeMs / duration
    }

    mutating func snapshotAndReset() -> PerformanceFrameStatsSnapshot {
        let snapshot = PerformanceFrameStatsSnapshot(
            sampleCount: sampleCount,
            averageMs: averageMs,
            worstMs: worstMs,
            hitchTimeMs: hitchTimeMs,
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
    let hitchTimeMs: Double
    let over60BudgetCount: Int
    let over20MsCount: Int
    let over33MsCount: Int
    let over50MsCount: Int
    let over100MsCount: Int

    var isEmpty: Bool { sampleCount == 0 }

    func hitchRatioMsPerSecond(overDuration duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return hitchTimeMs / duration
    }
}

final class PerformanceLogWriter {
    private let queue = DispatchQueue(label: "app.trynox.nox.performance-log", qos: .utility)
    private var fileHandle: FileHandle?

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }
    }

    func flush() {
        queue.sync {}
    }

    func close() {
        queue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}

@MainActor
final class PerformanceProbe: NSObject {
    static let shared = PerformanceProbe()
    private static let signpostLog = OSLog(
        subsystem: "app.trynox.nox",
        category: "Performance"
    )

    private let sampleInterval: TimeInterval = 1.0 / 60.0
    private let summaryInterval: CFTimeInterval = 1.0
    private let timestampFormatter: ISO8601DateFormatter

    private var timer: Timer?
    private var displayLink: AnyObject?
    private var lastTickTime: CFTimeInterval?
    private var summaryStartTime: CFTimeInterval?
    private var stats = PerformanceFrameStats()
    private var logWriter: PerformanceLogWriter?
    private var logURL: URL?
    private var contextProvider: (() -> String)?
    private var activeProvider: (() -> Bool)?

    private override init() {
        timestampFormatter = ISO8601DateFormatter()
        super.init()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func setContextProvider(_ provider: @escaping () -> String) {
        contextProvider = provider
    }

    func setActiveProvider(_ provider: @escaping () -> Bool) {
        activeProvider = provider
    }

    func start() {
        guard timer == nil, displayLink == nil else { return }
        guard prepareLogFile() else { return }

        let now = CACurrentMediaTime()
        lastTickTime = now
        summaryStartTime = now

        let sampleHz: String
        if startDisplayLinkSampler() {
            sampleHz = "displayLink"
        } else {
            startTimerSampler()
            sampleHz = "60"
        }

        mark("SESSION_START", metadata: [
            "sampleHz": sampleHz,
            "budgetMs": formatMs(PerformanceFrameStats.sixtyFPSBudgetMs)
        ])

        if let logURL {
            NSLog("nox: performance probe writing to %@", logURL.path)
        }
    }

    func stop() {
        mark("SESSION_STOP")
        if #available(macOS 14.0, *), let displayLink = displayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        displayLink = nil
        timer?.invalidate()
        timer = nil
        logWriter?.close()
        logWriter = nil
    }

    func mark(_ name: String, metadata: [String: String] = [:]) {
        var fields = [field("name", name)]
        fields.append(contentsOf: metadataFields(metadata))
        fields.append(field("context", contextProvider?() ?? "none"))
        writeEvent("MARK", fields: fields)
        os_signpost(.event, log: Self.signpostLog, name: "PerformanceMark", "%{public}s", name)
    }

    func currentLogURL() -> URL? {
        logURL
    }

    private func startTimerSampler() {
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { _ in
            Task { @MainActor in
                PerformanceProbe.shared.handleTimerFire()
            }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startDisplayLinkSampler() -> Bool {
        if #available(macOS 14.0, *),
           let displayLink = NSScreen.main?.displayLink(
                target: self,
                selector: #selector(handleDisplayLink(_:))
           ) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 60,
                preferred: 60
            )
            displayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
            self.displayLink = displayLink
            return true
        }
        return false
    }

    @available(macOS 14.0, *)
    @objc private func handleDisplayLink(_ displayLink: CADisplayLink) {
        handleSampleFire(now: CACurrentMediaTime())
    }

    private func handleTimerFire() {
        handleSampleFire(now: CACurrentMediaTime())
    }

    private func handleSampleFire(now: CFTimeInterval) {
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
        let summaryDuration = now - summaryStart
        if summaryDuration >= summaryInterval {
            let snapshot = stats.snapshotAndReset()
            summaryStartTime = now
            guard !snapshot.isEmpty else { return }
            writeEvent("SUMMARY", fields: [
                field("samples", snapshot.sampleCount),
                field("avgMs", formatMs(snapshot.averageMs)),
                field("worstMs", formatMs(snapshot.worstMs)),
                field("hitchMs", formatMs(snapshot.hitchTimeMs)),
                field("hitchRatio", formatMs(snapshot.hitchRatioMsPerSecond(overDuration: summaryDuration))),
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
            logWriter = try PerformanceLogWriter(url: url)
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
        guard let logWriter else { return }
        let timestamp = timestampFormatter.string(from: Date())
        let line = ([timestamp, event] + fields).joined(separator: " ") + "\n"
        logWriter.write(line)
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
