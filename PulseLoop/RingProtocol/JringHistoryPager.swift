import Foundation

/// The jring history pager: one day at a time, and the next request is held until the current day's
/// stream has finished. Ported from the Android sister app's `JringHistorySync`.
///
/// The ring answers one history request at a time; a second request mid-stream truncates the first.
/// So per day this sends `0x10 <day>` (per-minute step slots + sleep stages), waits for that stream to
/// go quiet, then sends `0x16 <day>` (1-minute HR blocks) and waits for its `0xFF` end marker (or the
/// same quiet timeout), then moves to the next day.
///
/// Replays are safe: activity buckets upsert by start time and HR history dedups on
/// `(kind, timestamp)`, so a timer that fires early only costs a re-request.
@MainActor
final class JringHistoryPager {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private enum Leg { case activity, heartRate }

    private weak var writer: RingCommandWriter?
    private let encoder = RingEncoder()
    /// Quiet period that ends a leg once frames have started arriving.
    private let settleNanos: UInt64
    /// Bound on a leg that never answers at all. Well under the ring's ~20 s idle disconnect.
    private let stallNanos: UInt64

    private var queue: [Int] = []
    private var leg: Leg = .activity
    private(set) var currentDay: Int?
    private var timer: Task<Void, Never>?
    /// Invalidates a timer that fires for a leg which has since moved on.
    private var epoch = 0

    init(writer: RingCommandWriter?, settleSeconds: Double = 3, stallSeconds: Double = 6) {
        self.writer = writer
        self.settleNanos = UInt64(settleSeconds * 1_000_000_000)
        self.stallNanos = UInt64(stallSeconds * 1_000_000_000)
    }

    var isRunning: Bool { currentDay != nil }

    /// Seed the queue and request the first day. Returns whether this call began a pass. A pass already
    /// in flight wins (restarting would truncate the day being streamed), and the `false` tells the
    /// caller not to consume its once-per-connection backfill gate.
    @discardableResult
    func start(days: [Int]) -> Bool {
        guard !isRunning, !days.isEmpty else { return false }
        queue = days
        advance()
        return true
    }

    /// Abandon any in-flight pass (disconnect / teardown).
    func cancel() {
        cancelTimer()
        currentDay = nil
        queue.removeAll()
    }

    /// Called for every inbound frame so the pager can tell a live stream from a finished one.
    /// Only fixed 20-byte frames count; fragments must not re-arm the quiet window.
    func noteFrame(_ data: Data) {
        guard isRunning, data.count == 20, let cmd = data.first else { return }
        switch cmd {
        case 0x10, 0x11:
            if leg == .activity { armTimer(settleNanos) }
        case 0x16:
            guard leg == .heartRate else { return }
            // 0x16 FF is the one genuine end-of-stream marker in this protocol.
            if data[data.startIndex + 1] == 0xff { advance() } else { armTimer(settleNanos) }
        default:
            break
        }
    }

    /// Treat the current leg as quiet right now (what the timer does when it fires).
    func legSettled() {
        guard isRunning else { return }
        switch leg {
        case .activity: beginHeartRateLeg()
        case .heartRate: advance()
        }
    }

    // MARK: - Driving the queue

    private func advance() {
        cancelTimer()
        guard !queue.isEmpty else {
            currentDay = nil
            return
        }
        let day = queue.removeFirst()
        currentDay = day
        leg = .activity
        writer?.enqueue(encoder.makeHistoryQueryCommand(dayOffset: day))
        armTimer(stallNanos)
    }

    private func beginHeartRateLeg() {
        guard let day = currentDay else { return }
        cancelTimer()
        leg = .heartRate
        writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand(dayOffset: day))
        armTimer(stallNanos)
    }

    private func armTimer(_ nanos: UInt64) {
        timer?.cancel()
        epoch &+= 1
        let armed = epoch
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.epoch == armed else { return }
            self.legSettled()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        epoch &+= 1
    }
}
