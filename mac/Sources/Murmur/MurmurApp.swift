import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Murmur").font(.headline)
                Spacer()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Picker("Mode", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case let .loadingModel(p) = model.phase, p > 0, p < 1 {
                ProgressView(value: p)
            }

            if !model.isConfigured {
                Label("Set the server URL and token in Settings.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            uploadStatus

            Divider()

            if model.recent.isEmpty {
                Text("Nothing transcribed yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.recent) { seg in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(seg.startedAt, style: .time)
                                    if seg.mode == "ptt" { Image(systemName: "mic.fill") }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                Text(seg.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            HStack {
                Button("Open murmur") { model.openWeb() }
                    .disabled(model.serverURL.isEmpty)
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    @ViewBuilder private var uploadStatus: some View {
        HStack(spacing: 6) {
            if let err = model.upload.lastError {
                Image(systemName: "icloud.slash").foregroundStyle(.red)
                Text(err).lineLimit(2)
            } else if model.upload.queued > 0 {
                Image(systemName: "icloud.and.arrow.up")
                Text("\(model.upload.queued) waiting to upload")
            } else if let at = model.upload.lastSentAt {
                Image(systemName: "checkmark.icloud")
                Text("Sent ") + Text(at, style: .relative) + Text(" ago")
            }
            Spacer()
            if model.upload.queued > 0 {
                Button("Send now") { model.flush(force: true) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $model.serverURL, prompt: Text("https://murmur.example.com"))
                SecureField("Token", text: $model.token)
                TextField("This device", text: $model.deviceName)
                HStack {
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true
                        Task {
                            let err = await model.testConnection()
                            testResult = err ?? "Connected"
                            testing = false
                        }
                    }
                    .disabled(testing || !model.isConfigured)
                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(testResult == "Connected" ? .green : .red)
                            .font(.callout)
                    }
                }
            }
            Section("Listening") {
                Picker("Push-to-talk / Toggle key", selection: $model.pttKey) {
                    ForEach(HoldKey.Key.allCases) { Text($0.label).tag($0) }
                }
                Text("Push to talk records while the key is held. Toggle starts on one press and stops on the next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.mode.usesKey && !HoldKey.trusted {
                    HStack {
                        Text("This mode needs the Accessibility permission.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button("Grant…") { HoldKey.askForPermission() }
                    }
                }
                VStack(alignment: .leading) {
                    Slider(value: $model.sensitivity, in: 0.4...0.95) {
                        Text("Speech detection")
                    } minimumValueLabel: {
                        Text("Sensitive").font(.caption)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption)
                    }
                    Text("Takes effect after a restart of Murmur.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Button("Clear recent transcripts in the menu") { model.clearRecent() }
            }
            Section {
                Text("Speech is transcribed on this Mac with Parakeet v3. Only the text is sent to your server; audio never leaves the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
