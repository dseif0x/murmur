import AppIntents

/// Starts a recording, or stops and sends the running one. Bind it to the
/// Action Button (Settings → Action Button → Shortcut → Murmur), run it from
/// Siri ("Record with Murmur") or a Shortcut / Control Center.
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record with Murmur"
    static var description = IntentDescription("Starts recording; run it again to stop and send the transcript.")
    // the microphone can only be started from the foreground
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.toggleFromIntent()
        return .result()
    }
}

/// Stops and sends the running recording (no-op otherwise).
struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Murmur recording"
    static var description = IntentDescription("Stops the running recording and sends the transcript.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if AppModel.shared.isRecording { AppModel.shared.stopRecording() }
        return .result()
    }
}

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "\(.applicationName) aufnehmen",
                "Start \(.applicationName)",
            ],
            shortTitle: "Record",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "\(.applicationName) stoppen",
            ],
            shortTitle: "Stop",
            systemImageName: "stop.fill"
        )
    }
}
