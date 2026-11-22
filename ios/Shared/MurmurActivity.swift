import ActivityKit
import AppIntents
import Foundation

/// The Live Activity murmur shows while it listens or records (lock screen,
/// Dynamic Island). Shared by the app (starts/updates it) and the widget
/// extension (draws it).
struct MurmurActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// true: a button/Siri recording; false: Always mode listening
        var recording: Bool
        /// transcripts since the activity started
        var transcripts: Int
    }

    var startedAt: Date
}

/// "Stop" on the Live Activity: ends a running recording, or stops Always
/// mode. A LiveActivityIntent runs in the app's process without opening it.
struct StopListeningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Murmur"
    static var description = IntentDescription("Stops the running recording or Always-mode listening.")

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { AppModel.shared.stopFromLiveActivity() }
        #endif
        return .result()
    }
}
