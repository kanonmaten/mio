import SwiftUI

/// Shows the listening bar above the tab bar while a session runs. The accessory's
/// show/hide variant needs iOS 26.1; on 26.0 the Live Activity and Fånga still show the state.
struct MioListeningAccessory: ViewModifier {
    let model: MioViewModel

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: MioListeningBar.isShown(for: model.runState)) {
                MioListeningBar(model: model)
            }
        } else {
            content
        }
    }
}

/// Deliberately discreet: a small dot and one word, no red, no waveform. Tapping opens Fånga.
struct MioListeningBar: View {
    let model: MioViewModel
    @Environment(MioNavigationCoordinator.self) private var navigation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    static func isShown(for state: MioRunState) -> Bool {
        switch state {
        case .listening, .paused, .interrupted, .preparing, .stopping: true
        case .off, .failed, .unavailable: false
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { navigation.selectedTab = .capture } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if placement != .inline, model.runState == .listening, let started = model.currentSession?.startedAt {
                        Text(started, style: .timer)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title). Öppna Fånga")
            .accessibilityIdentifier("mio.listening-bar")

            switch model.runState {
            case .listening:
                Button {
                    Task { await model.pause(.untilResumed) }
                } label: {
                    Image(systemName: "pause.fill").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isLessonActive ? "Pausa lektionen" : "Pausa Mio")
            case .paused:
                Button { model.beginListening() } label: {
                    Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isLessonActive ? "Fortsätt lektionen" : "Fortsätt Mio")
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
    }

    private var title: String {
        switch model.runState {
        case .listening: model.isLessonActive ? "Lektion" : "Lyssnar"
        case .paused: "Pausad"
        case .interrupted: "Avbruten, fortsätter snart"
        case .preparing: "Startar"
        case .stopping: "Stänger"
        case .off, .failed, .unavailable: "Av"
        }
    }

    private var dotColor: Color {
        switch model.runState {
        case .listening: MioTheme.tint
        case .interrupted: .orange
        default: .secondary
        }
    }
}
