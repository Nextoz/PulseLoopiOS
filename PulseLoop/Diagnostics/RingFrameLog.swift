import Foundation

/// A capped, local-only log of every jring frame sent to or received from the ring (timestamp,
/// direction, hex), kept as one JSON Lines file per day under Application Support and pruned to the
/// last `retentionDays` days. It is independent of the SwiftData `RawPacketRow` trace (which is opt-in
/// and capped at a few thousand rows) so a protocol question about an older sync can still be
/// answered from the raw bytes. Nothing here touches the network; export goes through the share sheet.
///
/// Raw frames encode health readings: the log never leaves the device unless the user exports it.
nonisolated final class RingFrameLog: @unchecked Sendable {
    nonisolated static let shared = RingFrameLog()

    static let retentionDays = 30

    private let directory: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "RingFrameLog", qos: .utility)
    private let stamp = ISO8601DateFormatter()
    private var prunedThisSession = false

    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? RingFrameLog.defaultDirectory()
        self.now = now
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RingFrames", isDirectory: true)
    }

    // MARK: - Writing

    /// One JSON line for a frame. Hex and the fixed keys need no escaping.
    static func line(timestamp: String, incoming: Bool, hex: String) -> String {
        let dir = incoming ? "in" : "out"
        return "{\"t\":\"\(timestamp)\",\"dir\":\"\(dir)\",\"hex\":\"\(hex)\"}\n"
    }

    /// Append a frame. Fire-and-forget on a background queue; failures are swallowed (a diagnostic
    /// log must never disturb the BLE path).
    func append(incoming: Bool, _ data: Data) {
        let when = now()
        let hex = data.map { String(format: "%02x", $0) }.joined()
        queue.async { [self] in
            if !prunedThisSession {
                prunedThisSession = true
                pruneLocked()
            }
            let text = Self.line(timestamp: stamp.string(from: when), incoming: incoming, hex: hex)
            writeLocked(text, to: fileURL(for: when))
        }
    }

    private func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("frames-\(Self.dayName(date)).jsonl")
    }

    /// UTC day name, so files rotate at a fixed instant regardless of the phone's time zone.
    private static func dayName(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func writeLocked(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Retention

    /// Delete day files older than `retentionDays`. Synchronous barrier so tests can observe it.
    func prune() {
        queue.sync { pruneLocked() }
    }

    private func pruneLocked() {
        let cutoff = Self.dayName(now().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasPrefix("frames-") && name.hasSuffix(".jsonl") {
            let day = String(name.dropFirst("frames-".count).dropLast(".jsonl".count))
            if day < cutoff {   // yyyy-MM-dd sorts lexicographically
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Export

    /// Concatenate every retained day (oldest first) into one temporary JSON Lines file and return it.
    func exportFile() throws -> URL {
        try queue.sync {
            pruneLocked()
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasPrefix("frames-") && $0.hasSuffix(".jsonl") }
                .sorted()
            let out = fm.temporaryDirectory
                .appendingPathComponent("ring-frames-\(Self.dayName(now())).jsonl")
            try? fm.removeItem(at: out)
            fm.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            for name in names {
                if let chunk = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                    try handle.write(contentsOf: chunk)
                }
            }
            return out
        }
    }

    /// Wait for queued appends (tests).
    func flush() {
        queue.sync {}
    }
}
