import XCTest
import SwiftData
@testable import PulseLoop

/// jring per-minute step history (0x10), per-day backfill paging, sleep windows (0x09) and the raw
/// frame log. Every frame here is SYNTHETIC: it follows the verified byte layouts but carries made-up
/// values (no captured data, no device addresses).
@MainActor
final class JringHistoryTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// `[opcode, byte1]` for each sent command.
        var heads: [[UInt8]] { sent.map { [$0[0], $0[1]] } }
    }

    private func utcDecoder() -> RingDecoder {
        RingDecoder(clock: JringClock(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Synthetic 0x10 reply: cmd, u32 slot start, 15 per-minute step counts.
    private func stepsFrame(slotStart: UInt32, perMinute: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x10] + le32(slotStart)
        bytes += perMinute + [UInt8](repeating: 0, count: 15 - perMinute.count)
        return Data(bytes)
    }

    private func frame(_ head: [UInt8]) -> Data {
        Data(head + [UInt8](repeating: 0, count: 20 - head.count))
    }

    // MARK: - Encoder

    func testHistoryQueriesCarryDayOffsetAndClamp() {
        let enc = RingEncoder()
        XCTAssertEqual(Array([UInt8](enc.makeHistoryQueryCommand(dayOffset: 3)).prefix(2)), [0x10, 3])
        XCTAssertEqual(Array([UInt8](enc.makeHistoryMeasurementQueryCommand(dayOffset: 6)).prefix(2)), [0x16, 6])
        XCTAssertEqual(Array([UInt8](enc.makeHistoryQueryCommand(dayOffset: 99)).prefix(2)), [0x10, 27])
        XCTAssertEqual(Array([UInt8](enc.makeHistoryMeasurementQueryCommand(dayOffset: -4)).prefix(2)), [0x16, 0])
        XCTAssertEqual(enc.makeHistoryQueryCommand().count, 20)
        XCTAssertEqual([UInt8](enc.makeHistoryQueryCommand()), [0x10] + [UInt8](repeating: 0, count: 19))
    }

    func testSleepWindowsCommandLayout() {
        let enc = RingEncoder()
        let bytes = [UInt8](enc.makeSleepWindowsCommand(.default))
        XCTAssertEqual(bytes.count, 20)
        // nap 13:00-18:00, night 21:00-11:00
        XCTAssertEqual(Array(bytes[0..<9]), [0x09, 13, 0, 18, 0, 21, 0, 11, 0])
        XCTAssertEqual(Array(bytes[9...]), [UInt8](repeating: 0, count: 11))

        let custom = JringSleepWindows(napStartMinutes: 12 * 60 + 30, napEndMinutes: 14 * 60 + 5,
                                       nightStartMinutes: 22 * 60 + 17, nightEndMinutes: 7 * 60)
        XCTAssertEqual(Array([UInt8](enc.makeSleepWindowsCommand(custom))[0..<9]),
                       [0x09, 12, 30, 14, 5, 22, 17, 7, 0])
    }

    // MARK: - Decoder

    func testStepsSlotDecodesToOneBucketWithSummedSteps() {
        let slot: UInt32 = 1_700_000_100
        let data = stepsFrame(slotStart: slot, perMinute: [0, 3, 10, 0, 25, 1, 0, 0, 7, 0, 0, 0, 0, 0, 2])
        let events = utcDecoder().decodeAll(data)
        XCTAssertEqual(events.count, 1)
        guard case let .activityBucket(timestamp, steps, distance) = events[0] else {
            return XCTFail("expected activityBucket, got \(events[0])")
        }
        XCTAssertEqual(steps, 48)
        XCTAssertEqual(distance, 0)
        XCTAssertEqual(timestamp, Date(timeIntervalSince1970: TimeInterval(slot)))
    }

    func testAllZeroStepsSlotIsAnAckNotABucket() {
        let events = utcDecoder().decodeAll(stepsFrame(slotStart: 1_700_000_000, perMinute: []))
        guard case .commandAck(commandId: 0x10) = events.first else {
            return XCTFail("expected ack, got \(events)")
        }
    }

    func testStepsSlotUsesRingClockOffset() {
        // Ring stamps are local wall-clock: with a +2h clock the true instant is 2h earlier.
        let clock = JringClock(timeZone: TimeZone(secondsFromGMT: 7200)!)
        let slot: UInt32 = 1_700_000_100
        let events = RingDecoder(clock: clock).decodeAll(stepsFrame(slotStart: slot, perMinute: [5]))
        guard case let .activityBucket(timestamp, _, _) = events.first else { return XCTFail() }
        XCTAssertEqual(timestamp, Date(timeIntervalSince1970: TimeInterval(slot) - 7200))
    }

    /// Re-syncing the same slots, and today's live 0x03 total, must not double count.
    func testStepsDoNotDoubleCountAcrossResyncAndLiveTotal() throws {
        let context = try TestSupport.makeContext()
        let dayStart = Calendar.current.startOfDay(for: Date().addingTimeInterval(-3 * 86_400))
        let first = UInt32(dayStart.timeIntervalSince1970) + 10 * 3600
        let slots = [first, first + 900, first + 1800]
        let decoder = utcDecoder()
        for _ in 0..<2 {   // two passes over the same history
            for slot in slots {
                for event in decoder.decodeAll(stepsFrame(slotStart: slot, perMinute: [10, 10])) {
                    guard case let .activityBucket(ts, steps, dist) = event else { continue }
                    ActivityService.applyActivityBucket(date: ts, steps: steps, distanceMeters: dist, context: context)
                }
            }
        }
        let day = try XCTUnwrap(MetricsRepository.activity(on: dayStart, context: context))
        XCTAssertEqual(day.steps, 60)

        // Today: live total (0x03) is the ceiling; bucket sums that agree with it don't add to it.
        let todayStart = Calendar.current.startOfDay(for: Date())
        ActivityService.applyActivityUpdate(
            ActivityDailyUpdate(date: Date(), steps: 40, source: "live"), context: context)
        let todaySlot = UInt32(todayStart.timeIntervalSince1970) + 60
        for _ in 0..<2 {
            for event in decoder.decodeAll(stepsFrame(slotStart: todaySlot, perMinute: [20, 20])) {
                guard case let .activityBucket(ts, steps, dist) = event else { continue }
                ActivityService.applyActivityBucket(date: ts, steps: steps, distanceMeters: dist, context: context)
            }
        }
        let today = try XCTUnwrap(MetricsRepository.activity(on: todayStart, context: context))
        XCTAssertEqual(today.steps, 40)
    }

    // MARK: - Phase 2 decoders (synthetic frames)

    func testSpO2HistoryFrame() {
        let ts: UInt32 = 1_700_000_900
        let data = Data([0x40] + le32(ts) + [UInt8](repeating: 97, count: 15))
        guard case let .historyMeasurement(kind, value, when) = utcDecoder().decodeAll(data)[0] else {
            return XCTFail()
        }
        XCTAssertEqual(kind, .spo2)
        XCTAssertEqual(value, 97)
        XCTAssertEqual(when, Date(timeIntervalSince1970: TimeInterval(ts)))
        // The all-zero end-of-day slot stores nothing.
        let end = Data([0x40] + le32(ts) + [UInt8](repeating: 0, count: 15))
        guard case .commandAck(commandId: 0x40) = utcDecoder().decodeAll(end)[0] else { return XCTFail() }
    }

    func testVitals55FrameMapsBloodPressureAndConfiguredFields() {
        let ts: UInt32 = 1_700_000_900
        let record: [UInt8] = [112, 72, 30, 55, 81]
        let data = Data([0x55] + le32(ts) + record + record + record)
        let events = utcDecoder().decodeAll(data)
        var seen: [MeasurementKind: Double] = [:]
        for case let .historyMeasurement(kind, value, _) in events { seen[kind] = value }
        XCTAssertEqual(seen[.bloodPressureSystolic], 112)
        XCTAssertEqual(seen[.bloodPressureDiastolic], 72)
        // f3, f4, f5 follow the single (unverified) mapping constant.
        for (i, kind) in RingDecoder.history55FieldKinds.enumerated() {
            if let kind { XCTAssertEqual(seen[kind], Double(record[2 + i])) }
        }
        let end = Data([0x55] + le32(ts) + [UInt8](repeating: 0, count: 15))
        guard case .commandAck(commandId: 0x55) = utcDecoder().decodeAll(end)[0] else { return XCTFail() }
    }

    func testTemperatureHistoryAndLiveUsePlausibilityRule() {
        let ts: UInt32 = 1_700_000_900
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        // Sample 0: 3650 -> 36.5 (/100). Sample 1: 362 -> 36.2 (/10). Sample 2: implausible.
        let body = le16(3650) + le16(0) + le16(362) + le16(0) + le16(9999) + le16(1)
        let data = Data([0x39] + le32(ts) + body + [0, 0, 0])
        let events = utcDecoder().decodeAll(data)
        var temps: [(Double, Date)] = []
        for case let .historyMeasurement(kind, value, when) in events where kind == .temperature {
            temps.append((value, when))
        }
        XCTAssertEqual(temps.count, 2)
        XCTAssertEqual(temps[0].0, 36.5, accuracy: 0.001)
        XCTAssertEqual(temps[1].0, 36.2, accuracy: 0.001)
        XCTAssertEqual(temps[1].1.timeIntervalSince(temps[0].1), 300)

        let live = utcDecoder().decodeAll(Data([0x38] + le16(3712) + le16(0)))
        guard case let .temperatureSample(celsius, _) = live[0] else { return XCTFail() }
        XCTAssertEqual(celsius, 37.12, accuracy: 0.001)
        guard case .commandAck(commandId: 0x38) = utcDecoder().decodeAll(Data([0x38] + le16(5) + le16(7)))[0]
        else { return XCTFail() }
    }

    func testPhase2Encoders() {
        let enc = RingEncoder()
        XCTAssertEqual(Array([UInt8](enc.makeSpO2HistoryQueryCommand(dayOffset: 2)).prefix(2)), [0x40, 2])
        XCTAssertEqual(Array([UInt8](enc.makeVitalsHistoryQueryCommand(dayOffset: 5)).prefix(2)), [0x55, 5])
        XCTAssertEqual(Array([UInt8](enc.makeTemperatureModeCommand(enabled: true)).prefix(2)), [0x37, 1])
        XCTAssertEqual(Array([UInt8](enc.makeTemperatureModeCommand(enabled: false)).prefix(2)), [0x37, 0])
    }

    // MARK: - Pager

    func testPagerRequestsOneDayAtATimeAndAdvancesOnStreamEnd() {
        let writer = FakeWriter()
        let pager = JringHistoryPager(writer: writer, settleSeconds: 3600, stallSeconds: 3600)
        XCTAssertTrue(pager.start(days: [0, 1]))
        XCTAssertEqual(writer.heads, [[0x10, 0]])
        XCTAssertFalse(pager.start(days: [4]), "a pass in flight must not be restarted")

        // Day 0 activity stream arrives, then goes quiet -> HR leg.
        pager.noteFrame(stepsFrame(slotStart: 1_700_000_000, perMinute: [4]))
        XCTAssertEqual(writer.heads.count, 1, "must wait for the stream to settle")
        pager.legSettled()
        XCTAssertEqual(writer.heads, [[0x10, 0], [0x16, 0]])

        // HR stream: F0 header, AA block header, A0 data, then FF ends the day immediately.
        pager.noteFrame(frame([0x16, 0xf0]))
        pager.noteFrame(frame([0x16, 0xaa]))
        pager.noteFrame(frame([0x16, 0xa0]))
        XCTAssertEqual(writer.heads.count, 2)
        pager.noteFrame(frame([0x16, 0xff]))
        XCTAssertEqual(writer.heads, [[0x10, 0], [0x16, 0], [0x40, 0]])

        // SpO2 then BP/vitals legs: a data frame keeps waiting, the all-zero slot ends the leg.
        pager.noteFrame(frame([0x40, 1, 2, 3, 4, 97]))
        XCTAssertEqual(writer.heads.count, 3)
        pager.noteFrame(frame([0x40, 1, 2, 3, 4]))
        XCTAssertEqual(writer.heads.last, [0x55, 0])
        pager.noteFrame(frame([0x55, 1, 2, 3, 4, 110, 70]))
        XCTAssertEqual(writer.heads.count, 4)
        pager.noteFrame(frame([0x55, 1, 2, 3, 4]))
        XCTAssertEqual(writer.heads.last, [0x10, 1])

        // Empty past day: one all-zero slot, then quiet, then 16 FF, then empty 40 and 55.
        pager.noteFrame(stepsFrame(slotStart: 1_700_000_000, perMinute: []))
        pager.legSettled()
        pager.noteFrame(frame([0x16, 0xff]))
        pager.noteFrame(frame([0x40, 1, 2, 3, 4]))
        pager.noteFrame(frame([0x55, 1, 2, 3, 4]))
        XCTAssertEqual(writer.heads, [[0x10, 0], [0x16, 0], [0x40, 0], [0x55, 0],
                                      [0x10, 1], [0x16, 1], [0x40, 1], [0x55, 1]])
        XCTAssertFalse(pager.isRunning)
    }

    func testPagerIgnoresFramesForTheLegNotInFlight() {
        let writer = FakeWriter()
        let pager = JringHistoryPager(writer: writer, settleSeconds: 3600, stallSeconds: 3600)
        pager.start(days: [0, 1])
        pager.noteFrame(frame([0x16, 0xff]))   // stray FF during the activity leg
        XCTAssertEqual(writer.heads, [[0x10, 0]])
        pager.noteFrame(Data([0x10, 1, 2, 3]))   // short fragment is ignored
        pager.cancel()
        XCTAssertFalse(pager.isRunning)
        pager.noteFrame(frame([0x16, 0xff]))
        XCTAssertEqual(writer.heads.count, 1)
    }

    func testPagerAdvancesOnItsOwnTimers() async throws {
        let writer = FakeWriter()
        let pager = JringHistoryPager(writer: writer, settleSeconds: 0.02, stallSeconds: 0.02)
        pager.start(days: [0, 1])
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(writer.heads, [[0x10, 0], [0x16, 0], [0x40, 0], [0x55, 0],
                                      [0x10, 1], [0x16, 1], [0x40, 1], [0x55, 1]])
        XCTAssertFalse(pager.isRunning)
    }

    // MARK: - Engine

    private func makeEngine() -> (JringSyncEngine, FakeWriter) {
        let writer = FakeWriter()
        return (JringSyncEngine(writer: writer, clock: JringClock(),
                                historySettleSeconds: 0.02, historyStallSeconds: 0.02), writer)
    }

    func testFirstPassBackfillsSevenDaysThenLaterPassesOnlyToday() async throws {
        let (engine, writer) = makeEngine()
        engine.connectionDidStart()
        engine.runStartup()
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let legs: Set<UInt8> = [0x10, 0x16, 0x40, 0x55]
        let history = writer.heads.filter { legs.contains($0[0]) }
        var expected: [[UInt8]] = []
        for day in 0..<JringSyncEngine.firstSyncBackfillDays {
            expected += [[0x10, UInt8(day)], [0x16, UInt8(day)], [0x40, UInt8(day)], [0x55, UInt8(day)]]
        }
        XCTAssertEqual(history, expected)
        XCTAssertFalse(engine.isPagingHistory)

        writer.sent.removeAll()
        engine.runStartup()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(writer.heads.filter { legs.contains($0[0]) }, [[0x10, 0], [0x16, 0], [0x40, 0], [0x55, 0]])

        // A new connection backfills again.
        writer.sent.removeAll()
        engine.connectionDidStart()
        engine.runStartup()
        XCTAssertEqual(writer.heads.filter { $0[0] == 0x10 }, [[0x10, 0]])
        engine.connectionDidEnd()
    }

    func testStartupSendsSleepWindowsAfterMonitoringAndEditingResendsThem() {
        let (engine, writer) = makeEngine()
        var settings = MeasurementSettings.jringDefault
        settings.sleepWindows = JringSleepWindows(napStartMinutes: 14 * 60, napEndMinutes: 15 * 60,
                                                  nightStartMinutes: 22 * 60, nightEndMinutes: 9 * 60)
        engine.setMeasurementSettings(settings)
        engine.runStartup()
        let opcodes = writer.sent.map { $0[0] }
        let i19 = opcodes.firstIndex(of: 0x19)
        let i09 = opcodes.firstIndex(of: 0x09)
        XCTAssertNotNil(i09)
        XCTAssertEqual(i09, i19.map { $0 + 1 })
        XCTAssertEqual(Array([UInt8](writer.sent[i09!])[0..<9]), [0x09, 14, 0, 15, 0, 22, 0, 9, 0])
        // Temperature mode defaults OFF and is sent right after the sleep windows.
        XCTAssertEqual(Array([UInt8](writer.sent[i09! + 1]).prefix(2)), [0x37, 0])
        engine.connectionDidEnd()

        // Applying unchanged settings (e.g. a workout cadence bump) must not resend 0x09 ...
        writer.sent.removeAll()
        engine.applyMeasurementSettings(settings)
        XCTAssertFalse(writer.sent.contains { $0[0] == 0x09 })
        // ... but editing the windows does.
        settings.sleepWindows.nightEndMinutes = 8 * 60
        engine.applyMeasurementSettings(settings)
        XCTAssertEqual(writer.sent.filter { $0[0] == 0x09 }.count, 1)
    }

    // MARK: - Raw frame log

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RingFrameLogTests-\(UUID().uuidString)")
    }

    func testFrameLogWritesJSONLinesAndExports() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RingFrameLog(directory: dir, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        log.append(incoming: false, Data([0x10, 0x00]))
        log.append(incoming: true, Data([0x10, 0xab, 0xcd]))
        log.flush()
        let url = try log.exportFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String]
        XCTAssertEqual(first?["dir"], "out")
        XCTAssertEqual(first?["hex"], "1000")
        XCTAssertEqual(first?["t"], "2023-11-14T22:13:20.000Z")
        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        XCTAssertEqual(second?["dir"], "in")
        XCTAssertEqual(second?["hex"], "10abcd")
    }

    func testFrameLogKeepsThirtyDays() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Old frame written "40 days ago", recent one "now".
        let old = RingFrameLog(directory: dir, now: { base.addingTimeInterval(-40 * 86_400) })
        old.append(incoming: true, Data([1]))
        old.flush()
        let log = RingFrameLog(directory: dir, now: { base })
        log.append(incoming: true, Data([2]))
        log.flush()
        log.prune()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8).contains("\"hex\":\"02\""))
    }
}
