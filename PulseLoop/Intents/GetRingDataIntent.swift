import AppIntents
import SwiftData

/// Shortcuts action "Get ring data": returns the "ring-slots/1" JSON (15-minute slots of everything the
/// ring has stored) as text. Reads the local store only; no network, no Apple Health.
struct GetRingDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Get ring data"
    static let description = IntentDescription(
        "Returns your ring's stored steps, heart rate, SpO2, blood pressure and sleep as JSON in 15-minute slots.",
        categoryName: "Ring"
    )
    /// A Shortcuts automation can call this in the background.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Days", description: "How many days back (1 to 28).", default: 7)
    var days: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = try ModelContainerFactory.make()
        let context = ModelContext(container)
        let json = RingSlotsExport.export(days: days, context: context)
        return .result(value: json)
    }
}

struct PulseLoopShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetRingDataIntent(),
            phrases: ["Get ring data from \(.applicationName)"],
            shortTitle: "Get ring data",
            systemImageName: "circle.hexagongrid.circle"
        )
    }
}
