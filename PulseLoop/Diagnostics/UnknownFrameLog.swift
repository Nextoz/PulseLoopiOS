import Foundation

/// In-memory list of the latest ring frames the decoder doesn't understand (`.unknown`), for the
/// Ring Gestures lab screen: do a gesture, see whether the ring sent anything new. Gesture frames on
/// this ring have never been captured, so this is how their opcode is found. Not persisted (the 30-day
/// raw frame log already keeps every frame for export); started from `PulseLoopApp`.
@MainActor
@Observable
final class UnknownFrameLog {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = UnknownFrameLog()
    static let capacity = 50

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let commandId: UInt8
        /// The full 20-byte frame as hex; nil for a user "mark".
        let hex: String?
    }

    /// Newest first.
    private(set) var entries: [Entry] = []
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                // `.rawPacket` is published before decoding (always tagged unknown), so read the decoded
                // stream: `.decodedPacket(.unknown)` is what the decoder genuinely couldn't place.
                guard case let .decodedPacket(decoded) = event,
                      case let .unknown(commandId, raw) = decoded else { continue }
                self?.append(Entry(at: Date(), commandId: commandId,
                                   hex: raw.map { String(format: "%02X", $0) }.joined(separator: " ")))
            }
        }
    }

    /// A user marker ("I just did a gesture") so frames can be lined up with what the wearer did.
    func mark() {
        append(Entry(at: Date(), commandId: 0, hex: nil))
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }
}
