import XCTest
@testable import PulseLoop

/// Pure rule tests for the on-device health alerts. Synthetic slots only (never real health values),
/// in a fixed UTC calendar so hours and day keys are deterministic.
final class HealthAlertEngineTests: XCTestCase {
    typealias Slot = RingSlotsExport.Slot

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-10-29 at the given UTC hour/minute.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 29) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func evaluate(_ slots: [Slot], prefs: HealthAlertPrefs = HealthAlertPrefs(), now: Date,
                          state: HealthAlertState = HealthAlertState()) -> (alerts: [HealthAlert], state: HealthAlertState) {
        HealthAlertEngine.evaluate(slots: slots, prefs: prefs, state: state, now: now, calendar: cal)
    }

    /// Four asleep slots (02:00–02:45) of the night that ends on `day`.
    private func night(day: Int, hr: Int, hrv: Int?, temp: Double?) -> [Slot] {
        (0..<4).map { i in
            Slot(start: at(2, 15 * i, day: day), hr: hr, hrvMs: hrv, tempC: temp, sleepLightMin: 15)
        }
    }

    /// 14 ordinary nights before 29 Oct (15–28 Oct).
    private func baselineNights() -> [Slot] {
        (15...28).flatMap { night(day: $0, hr: 52, hrv: 50, temp: 35.8) }
    }

    // MARK: - Right-now rules

    func testHighHeartRateNeedsTwoRestingReadingsInARow() {
        let one = [Slot(start: at(14, 0), steps: 10, hr: 120), Slot(start: at(14, 15), steps: 10, hr: 80)]
        XCTAssertTrue(evaluate(one, now: at(15)).alerts.isEmpty)

        let two = [Slot(start: at(14, 0), steps: 10, hr: 120), Slot(start: at(14, 15), steps: 0, hr: 118)]
        let alerts = evaluate(two, now: at(15)).alerts
        XCTAssertEqual(alerts.map(\.kind), [.highHeartRateAtRest])
        XCTAssertTrue(alerts[0].body.contains("14:00"))
    }

    func testHighHeartRateWhileWalkingDoesNotAlert() {
        let walking = [Slot(start: at(14, 0), steps: 900, hr: 125), Slot(start: at(14, 15), steps: 850, hr: 128)]
        XCTAssertTrue(evaluate(walking, now: at(15)).alerts.isEmpty)
    }

    func testReadingsMoreThanThirtyMinutesApartAreNotInARow() {
        let apart = [Slot(start: at(14, 0), hr: 120), Slot(start: at(14, 45), hr: 120)]
        XCTAssertTrue(evaluate(apart, now: at(15)).alerts.isEmpty)
    }

    func testOldReadingsAreNotReplayed() {
        let old = [Slot(start: at(6, 0), hr: 120), Slot(start: at(6, 15), hr: 121)]
        XCTAssertTrue(evaluate(old, now: at(15)).alerts.isEmpty)
    }

    func testAlertFiresOncePerDay() {
        let slots = [Slot(start: at(14, 0), hr: 120), Slot(start: at(14, 15), hr: 121)]
        let first = evaluate(slots, now: at(15))
        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertTrue(evaluate(slots, now: at(15, 30), state: first.state).alerts.isEmpty)
        // A new day re-arms it.
        let nextDay = [Slot(start: at(14, 0, day: 30), hr: 120), Slot(start: at(14, 15, day: 30), hr: 121)]
        XCTAssertEqual(evaluate(nextDay, now: at(15, day: 30), state: first.state).alerts.count, 1)
    }

    func testNightSpO2DipsAcrossMidnightFireOnce() {
        let dips = [Slot(start: at(23, 0, day: 28), spo2: 86), Slot(start: at(23, 30, day: 28), spo2: 87),
                    Slot(start: at(23, 45, day: 28), spo2: 85)]
        let first = evaluate(dips, now: at(23, 50, day: 28))
        XCTAssertEqual(first.alerts.map(\.kind), [.lowSpO2Night])
        // After midnight the same readings are still in the 12-hour window: no repeat.
        XCTAssertTrue(evaluate(dips, now: at(0, 30), state: first.state).alerts.isEmpty)
        // A new dip after midnight may fire again on the new day.
        let more = dips + [Slot(start: at(1, 0), spo2: 84)]
        XCTAssertEqual(evaluate(more, now: at(1, 10), state: first.state).alerts.map(\.kind), [.lowSpO2Night])
    }

    func testLowHeartRateIgnoredWhileAsleep() {
        let asleep = [Slot(start: at(9, 0), hr: 38, sleepLightMin: 15), Slot(start: at(9, 15), hr: 37, sleepLightMin: 15)]
        XCTAssertTrue(evaluate(asleep, now: at(10)).alerts.isEmpty)
        let awake = [Slot(start: at(9, 0), hr: 38), Slot(start: at(9, 15), hr: 37)]
        XCTAssertEqual(evaluate(awake, now: at(10)).alerts.map(\.kind), [.lowHeartRateAwake])
    }

    func testLowSpO2NeedsThreeNightReadings() {
        let two = [Slot(start: at(1, 0), spo2: 87), Slot(start: at(1, 30), spo2: 88)]
        XCTAssertTrue(evaluate(two, now: at(7)).alerts.isEmpty)
        let three = two + [Slot(start: at(2, 0), spo2: 86)]
        let alerts = evaluate(three, now: at(7)).alerts
        XCTAssertEqual(alerts.map(\.kind), [.lowSpO2Night])
        XCTAssertTrue(alerts[0].body.contains("86%"))
        // Daytime dips (often motion) don't count.
        let day = [Slot(start: at(12, 0), spo2: 85), Slot(start: at(12, 30), spo2: 85), Slot(start: at(13, 0), spo2: 85)]
        XCTAssertTrue(evaluate(day, now: at(14)).alerts.isEmpty)
    }

    func testMasterSwitchOffSilencesEverything() {
        var prefs = HealthAlertPrefs()
        prefs.enabled = false
        let slots = [Slot(start: at(14, 0), hr: 150), Slot(start: at(14, 15), hr: 150)]
        XCTAssertTrue(evaluate(slots, prefs: prefs, now: at(15)).alerts.isEmpty)
    }

    // MARK: - Compared with your normal

    func testRestingHRRiseNeedsFourteenEarlierNights() {
        let tonight = night(day: 29, hr: 60, hrv: 50, temp: 35.8)
        let thirteen = (16...28).flatMap { night(day: $0, hr: 52, hrv: 50, temp: 35.8) }
        XCTAssertTrue(evaluate(thirteen + tonight, now: at(8)).alerts.isEmpty)

        let alerts = evaluate(baselineNights() + tonight, now: at(8)).alerts
        XCTAssertEqual(alerts.map(\.kind), [.restingHRRise])
        XCTAssertTrue(alerts[0].body.contains("60 bpm"))
    }

    func testRiseRulesWaitForTheMorning() {
        let slots = baselineNights() + night(day: 29, hr: 60, hrv: 50, temp: 35.8)
        XCTAssertTrue(evaluate(slots, now: at(5)).alerts.isEmpty)
    }

    func testTemperatureRise() {
        let slots = baselineNights() + night(day: 29, hr: 52, hrv: 50, temp: 36.4)
        XCTAssertEqual(evaluate(slots, now: at(8)).alerts.map(\.kind), [.temperatureRise])
    }

    func testCombinedStrainReplacesTheSingleRiseAlerts() {
        let slots = baselineNights() + night(day: 29, hr: 60, hrv: 38, temp: 36.4)
        XCTAssertEqual(evaluate(slots, now: at(8)).alerts.map(\.kind), [.combinedStrain])
    }

    func testAfternoonNapIsNotANight() {
        let nap = (0..<4).map { Slot(start: at(14, 15 * $0), hr: 70, sleepLightMin: 15) }
        XCTAssertNil(HealthAlertEngine.nightSummaries(nap, cal)["2026-10-29"])
    }

    // MARK: - No-data notice

    func testNoDataFireDateStaysInTheAwakeWindow() {
        XCTAssertEqual(HealthAlertEngine.noDataFireDate(lastReading: at(9), hours: 6, calendar: cal), at(15))
        // 19:00 + 6 h = 01:00 → 08:00 the same (next) morning.
        XCTAssertEqual(HealthAlertEngine.noDataFireDate(lastReading: at(19), hours: 6, calendar: cal), at(8, day: 30))
        // 17:00 + 6 h = 23:00 → 08:00 next morning.
        XCTAssertEqual(HealthAlertEngine.noDataFireDate(lastReading: at(17), hours: 6, calendar: cal), at(8, day: 30))
    }

    func testPrefsDecodeToleratesMissingKeys() throws {
        let decoded = try JSONDecoder().decode(HealthAlertPrefs.self, from: Data(#"{"highHeartRateBpm":120}"#.utf8))
        XCTAssertEqual(decoded.highHeartRateBpm, 120)
        XCTAssertEqual(decoded.lowSpO2Percent, HealthAlertPrefs.default.lowSpO2Percent)
        XCTAssertTrue(decoded.enabled)
    }
}
