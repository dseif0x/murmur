import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                VStack(spacing: 6) {
                    Text(model.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if case let .loadingModel(p) = model.phase {
                        if model.preparingModel {
                            ProgressView() // compiling: no meaningful fraction
                        } else if p > 0, p < 1 {
                            ProgressView(value: min(p, 0.5) * 2).padding(.horizontal, 40)
                        }
                    }
                }
                .frame(minHeight: 44)

                RecordButton()
                    .padding(.vertical, 8)

                notices

                RecentList()
            }
            .padding(.top, 8)
            .navigationTitle("Murmur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    UploadBadge()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .onAppear {
                if !model.isConfigured { showSettings = true }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if !model.isConfigured {
            Label("Set the server URL and token in Settings.", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if model.micDenied {
            Label("Microphone access is off: Settings → Murmur → Microphone.", systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if model.deferred > 0 {
            Label("\(model.deferred) recording(s) waiting to be transcribed", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The big round button: hold to talk, or tap to start / stop. In Always
/// mode it shows the listening state.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    @State private var pressed = false

    private var active: Bool { model.phase == .recording || model.phase == .hearing }

    private var icon: String {
        switch model.phase {
        case .recording: return "mic.fill"
        case .listening: return "waveform"
        case .hearing: return "waveform.circle.fill"
        case .off: return "mic.slash"
        case .error: return "exclamationmark.triangle"
        case .starting, .loadingModel: return "arrow.down.circle"
        case .idle: return "mic"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? Color.accentColor : Color(white: 0.16))
                .frame(width: 180, height: 180)
                .scaleEffect(pressed || model.phase == .recording ? 1.08 : 1)
                .shadow(color: active ? Color.accentColor.opacity(0.6) : .clear, radius: 24)
            Image(systemName: icon)
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(active ? Color.black : Color.accentColor)
        }
        .animation(.spring(duration: 0.25), value: model.phase)
        .animation(.spring(duration: 0.2), value: pressed)
        .opacity(model.mode.usesButton && !model.isBusy ? 1 : 0.6)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard model.mode.usesButton, !pressed else { return }
                    pressed = true
                    model.buttonDown()
                }
                .onEnded { _ in
                    guard pressed else { return }
                    pressed = false
                    model.buttonUp()
                }
        )
        .accessibilityLabel(model.phase == .recording ? "Stop recording" : "Record")
        .accessibilityAddTraits(.isButton)
    }
}

struct UploadBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.upload.lastError != nil {
            Button { model.flush(force: true) } label: {
                Label("\(model.upload.queued)", systemImage: "icloud.slash")
            }
            .tint(.orange)
        } else if model.upload.queued > 0 {
            Label("\(model.upload.queued)", systemImage: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.secondary)
        }
    }
}

struct RecentList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if model.recent.isEmpty {
                Text("Nothing transcribed yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(model.recent) { seg in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(seg.startedAt, format: .dateTime.day().month().hour().minute())
                                if seg.mode == "ptt" { Image(systemName: "mic.fill") }
                                if let s = seg.speaker { Text("· " + s) }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Text(seg.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Recent")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://murmur.example.com", text: $model.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Device name", text: $model.deviceName)
                    Button {
                        testing = true
                        Task {
                            let err = await model.testConnection()
                            testResult = err ?? "Connected."
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!model.isConfigured || testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Only the text is sent, never audio. Transcripts wait on the phone until the server takes them.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Slider(value: $model.sensitivity, in: 0.4...0.95)
                        Text("Higher ignores more background noise. Applies after a restart.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Always mode: speech detection")
                }

                Section {
                    Picker("Speakers", selection: $model.speakerMode) {
                        ForEach(SpeakerMode.allCases) { Text($0.label).tag($0) }
                    }
                    Text(model.speakerMode.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let p = model.voiceProfile {
                        LabeledContent("Your voice") {
                            Text(p.createdAt, format: .dateTime.day().month().year())
                        }
                    }
                    switch model.enrollment {
                    case let .recording(left):
                        Label("Speak normally… \(left) s", systemImage: "waveform")
                            .foregroundStyle(.orange)
                    case .processing:
                        HStack { Text("Processing…"); Spacer(); ProgressView() }
                    default:
                        Button(model.voiceProfile == nil ? "Record my voice (12 s)" : "Record my voice again") { model.enrollVoice() }
                        if model.voiceProfile != nil {
                            Button("Delete my voice", role: .destructive) { model.deleteVoiceProfile() }
                        }
                    }
                    if case let .failed(msg) = model.enrollment {
                        Text(msg).font(.footnote).foregroundStyle(.red)
                    }
                    if model.speakerMode.needsProfile && model.voiceProfile == nil {
                        Text("Record your voice first: until then nothing is dropped.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Speakers")
                } footer: {
                    Text("Read something aloud for 12 seconds. Only a voice fingerprint is kept, no audio; detection runs on this iPhone.")
                }

                Section {
                    LabeledContent("Waiting to upload", value: "\(model.upload.queued)")
                    if let sent = model.upload.lastSentAt {
                        LabeledContent("Last upload") { Text(sent, style: .relative) }
                    }
                    if let err = model.upload.lastError {
                        Text(err).font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Send now") { model.flush(force: true) }
                        .disabled(model.upload.queued == 0)
                } header: {
                    Text("Upload")
                }

                Section {
                    if let url = model.webURL {
                        Link("Open the web app", destination: url)
                    }
                    Button("Clear the list on this phone", role: .destructive) { model.clearRecent() }
                } footer: {
                    Text("Siri, Shortcuts and the Action Button: \"Murmur aufnehmen\" / \"Record with Murmur\" starts a recording; run it again to send.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
