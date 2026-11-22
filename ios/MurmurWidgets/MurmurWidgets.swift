import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MurmurWidgets: WidgetBundle {
    var body: some Widget {
        MurmurLiveActivity()
    }
}

private let accent = Color(red: 0.541, green: 0.706, blue: 1.0)

struct MurmurLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MurmurActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.051, green: 0.059, blue: 0.078))
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(statusText(context), systemImage: icon(context))
                        .foregroundStyle(accent)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(context.state.transcripts) transcripts")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !context.isStale {
                            Button(intent: StopListeningIntent()) {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.red)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context)).foregroundStyle(accent)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: icon(context)).foregroundStyle(accent)
            }
        }
    }
}

private func icon(_ context: ActivityViewContext<MurmurActivityAttributes>) -> String {
    if context.isStale { return "mic.slash" }
    return context.state.recording ? "mic.fill" : "waveform"
}

private func statusText(_ context: ActivityViewContext<MurmurActivityAttributes>) -> String {
    if context.isStale { return "Stopped" }
    return context.state.recording ? "Recording" : "Listening"
}

struct LockScreenView: View {
    let context: ActivityViewContext<MurmurActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon(context))
                .font(.title2)
                .foregroundStyle(context.isStale ? .orange : accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                if context.isStale {
                    Text("Murmur stopped").font(.headline)
                    Text("iOS closed the app. Open it to keep listening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("Murmur · \(statusText(context))").font(.headline)
                        Text(context.attributes.startedAt, style: .timer)
                            .monospacedDigit()
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(context.state.transcripts) transcripts since \(context.attributes.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !context.isStale {
                Button(intent: StopListeningIntent()) {
                    Image(systemName: "stop.fill")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
            }
        }
        .padding(16)
    }
}
