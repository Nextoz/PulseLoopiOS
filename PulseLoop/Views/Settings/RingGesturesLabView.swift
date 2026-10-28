import SwiftUI

/// Settings → Ring Gestures (lab). Lists ring frames the app doesn't recognise yet, live, so the wearer
/// can do a gesture and see whether the ring sends anything. Once a gesture's frame is known it gets
/// decoded and actions are added; until then this screen is the discovery tool.
struct RingGesturesLabView: View {
    @State private var log = UnknownFrameLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(
                    title: "Find the ring's gestures",
                    body: "Keep this screen open and the ring connected. Tap Mark, do one gesture on the ring, "
                        + "wait 5 seconds, and repeat a few times. Anything the ring sends that the app doesn't "
                        + "understand yet appears below. A screenshot of this list is enough to decode it."
                )

                SettingsGroup {
                    FormValueRow(title: "Mark a gesture") {
                        Button("Mark") { log.mark() }
                            .buttonStyle(.borderedProminent)
                    }
                    FormValueRow(title: "Clear the list") {
                        Button("Clear", role: .destructive) { log.clear() }
                    }
                }

                SettingsGroup(
                    header: "Unrecognised frames (newest first)",
                    footer: "Only frames the app can't decode. 0x13 arrives on every connect and is expected."
                ) {
                    if log.entries.isEmpty {
                        Text("Nothing yet.")
                            .font(PulseFont.body)
                            .foregroundStyle(PulseColors.textMuted)
                            .padding(16)
                    } else {
                        ForEach(log.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Ring Gestures (lab)")
    }

    @ViewBuilder private func row(_ entry: UnknownFrameLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.at.formatted(date: .omitted, time: .standard)
                 + (entry.hex == nil ? "  — MARK —" : String(format: "  0x%02X", entry.commandId)))
                .font(PulseFont.body.weight(.semibold))
                .foregroundStyle(entry.hex == nil ? PulseColors.accent : PulseColors.textPrimary)
            if let hex = entry.hex {
                Text(hex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PulseColors.textMuted)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
