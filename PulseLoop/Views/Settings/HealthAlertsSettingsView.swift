import SwiftUI

/// Settings → Health Alerts: on-device rules (`HealthAlertEngine`) that send a local notification
/// after a ring sync. Each rule is a toggle plus its limit. No AI and nothing leaves the phone.
struct HealthAlertsSettingsView: View {
    @State private var store = HealthAlertPrefsStore.shared

    private var on: Bool { store.prefs.enabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(
                    title: "Health alerts",
                    body: "Checked on your iPhone after each ring sync, so an alert can arrive up to an hour after "
                        + "the reading. Not a medical alarm or a diagnosis."
                )

                SettingsGroup {
                    FormToggleRow(title: "Health alerts", isOn: toggle(\.enabled))
                }

                Group {
                    SettingsGroup(
                        header: "Right now",
                        footer: "Heart rate needs two readings in a row. \"At rest\" means under 100 steps in the "
                            + "15 minutes. Blood oxygen counts readings at night or while asleep."
                    ) {
                        FormToggleRow(title: "High heart rate at rest", isOn: toggle(\.highHeartRateEnabled))
                        stepper("Above", \.highHeartRateBpm, in: 90...180, step: 5, unit: "bpm")
                        FormToggleRow(title: "Low heart rate while awake", isOn: toggle(\.lowHeartRateEnabled))
                        stepper("At or below", \.lowHeartRateBpm, in: 30...60, step: 1, unit: "bpm")
                        FormToggleRow(title: "Low blood oxygen at night", isOn: toggle(\.lowSpO2Enabled))
                        stepper("3+ readings below", \.lowSpO2Percent, in: 80...95, step: 1, unit: "%")
                    }

                    SettingsGroup(
                        header: "Compared with your normal",
                        footer: "Starts after 14 nights of sleep data. Checked each morning from 07:00 against the "
                            + "median of your earlier nights. The ring's temperature scale is still unverified."
                    ) {
                        FormToggleRow(title: "Resting heart rate up", isOn: toggle(\.restingHRRiseEnabled))
                        stepper("By at least", \.restingHRRiseBpm, in: 3...15, step: 1, unit: "bpm")
                        FormToggleRow(title: "Night temperature up", isOn: toggle(\.temperatureRiseEnabled))
                        FormValueRow(title: "By at least") {
                            Text(String(format: "%.1f °C", store.prefs.temperatureRiseC))
                                .foregroundStyle(PulseColors.textMuted)
                            Stepper("", value: Binding(
                                get: { store.prefs.temperatureRiseC },
                                set: { store.prefs.temperatureRiseC = ($0 * 10).rounded() / 10 }
                            ), in: 0.2...1.5, step: 0.1)
                            .labelsHidden()
                        }
                        FormToggleRow(title: "Possible strain or illness", isOn: toggle(\.combinedStrainEnabled))
                    }

                    SettingsGroup(
                        header: "Ring",
                        footer: "Arrives only between 08:00 and 22:00; a later gap is reported the next morning."
                    ) {
                        FormToggleRow(title: "No new ring data", isOn: toggle(\.noDataEnabled))
                        stepper("After", \.noDataHours, in: 2...12, step: 1, unit: "h")
                    }
                }
                .disabled(!on)
                .opacity(on ? 1 : 0.5)
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Health Alerts")
        .task { if on { await HealthAlertMonitor.requestPermissionIfNeeded() } }
    }

    private func toggle(_ keyPath: WritableKeyPath<HealthAlertPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.prefs[keyPath: keyPath] },
            set: {
                store.prefs[keyPath: keyPath] = $0
                if $0 { Task { await HealthAlertMonitor.requestPermissionIfNeeded() } }
            }
        )
    }

    private func stepper(
        _ title: String, _ keyPath: WritableKeyPath<HealthAlertPrefs, Int>,
        in range: ClosedRange<Int>, step: Int, unit: String
    ) -> some View {
        FormValueRow(title: title) {
            Text("\(store.prefs[keyPath: keyPath]) \(unit)")
                .foregroundStyle(PulseColors.textMuted)
            Stepper("", value: Binding(
                get: { store.prefs[keyPath: keyPath] },
                set: { store.prefs[keyPath: keyPath] = $0 }
            ), in: range, step: step)
            .labelsHidden()
        }
    }
}
