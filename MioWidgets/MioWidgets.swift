import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MioListeningLiveActivity()
    }
}

/// Lock Screen and Dynamic Island while Mio listens. Plain native styling; the visual
/// redesign restyles it later. No transcript text is ever shown here.
struct MioListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MioListeningAttributes.self) { context in
            MioListeningLockScreenView(state: context.state, isLesson: context.attributes.isLesson)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: context.state.symbolName)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MioListeningTimer(state: context.state)
                        .font(.headline)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let gaps = context.state.gapText {
                            Text(gaps).font(.footnote).foregroundStyle(.secondary)
                        }
                        MioListeningControls(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .accessibilityLabel(context.state.title)
            } compactTrailing: {
                MioListeningTimer(state: context.state)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .accessibilityLabel(context.state.title)
            }
        }
    }
}

struct MioListeningLockScreenView: View {
    let state: MioListeningActivityState
    let isLesson: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.symbolName)
                    .accessibilityHidden(true)
                Text(state.title)
                Text("·")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MioListeningTimer(state: state)
                Spacer(minLength: 0)
                if isLesson {
                    Text("Lektion")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.headline)
            if let gaps = state.gapText {
                Text(gaps)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            MioListeningControls(state: state)
        }
        .padding()
    }
}

/// Rendered by the system from the session start, so the activity needs no frequent updates.
struct MioListeningTimer: View {
    let state: MioListeningActivityState

    var body: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, pauseTime: state.pausedAt,
             countsDown: false, showsHours: true)
            .monospacedDigit()
    }
}

struct MioListeningControls: View {
    let state: MioListeningActivityState

    var body: some View {
        HStack(spacing: 12) {
            if state.isPaused {
                Button(intent: MioResumeListeningIntent()) {
                    Label("Fortsätt", systemImage: "play.fill")
                }
            } else {
                Button(intent: MioPauseListeningIntent()) {
                    Label("Pausa", systemImage: "pause.fill")
                }
            }
            Button(intent: MioStopListeningIntent()) {
                Label("Stopp", systemImage: "stop.fill")
            }
        }
        .buttonStyle(.bordered)
    }
}
