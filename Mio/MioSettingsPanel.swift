import SwiftUI

extension View {
    /// The single settings panel: slides in from the right edge over the app. Opens with the
    /// top-right settings button or a swipe from the right edge; closes with Klar, a tap outside,
    /// a swipe to the right or the VoiceOver escape gesture.
    func mioSettingsPanel<Panel: View>(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void,
                                       @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(MioSettingsPanelModifier(isPresented: isPresented, onDismiss: onDismiss, panel: panel))
    }
}

private struct MioSettingsPanelModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let panel: () -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    private let edgeWidth: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isPresented)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .trailing) {
                // A thin strip at the right edge, clear of the navigation and tab bars, so lists and
                // scroll views keep their own gestures.
                if !isPresented {
                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 16)
                                .onEnded { value in
                                    if value.translation.width < -50, abs(value.translation.height) < 80 { isPresented = true }
                                })
                        .padding(.vertical, 120)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                ZStack(alignment: .trailing) {
                    if isPresented {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        MioSettingsPanelChrome(close: { isPresented = false }, panel: panel)
                            .frame(width: min(max(width - 44, 280), 460))
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32), value: isPresented)
            }
            .onChange(of: isPresented) { _, presented in if !presented { onDismiss() } }
    }
}

private struct MioSettingsPanelChrome<Panel: View>: View {
    let close: () -> Void
    let panel: () -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AccessibilityFocusState private var titleFocused: Bool
    @GestureState private var dragOffset: CGFloat = 0
    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inställningar")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 12)
                Button("Klar", action: close)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("mio.settings.done")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            NavigationStack { panel() }
        }
        .background { chromeBackground }
        .clipShape(shape)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .offset(x: reduceMotion ? 0 : dragOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($dragOffset) { value, state, _ in state = max(0, value.translation.width) }
                .onEnded { value in
                    if value.translation.width > 90, abs(value.translation.height) < abs(value.translation.width) { close() }
                })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .accessibilityIdentifier("mio.settings.panel")
        .task {
            // VoiceOver needs the panel on screen before focus can move into it.
            try? await Task.sleep(for: .milliseconds(350))
            titleFocused = true
        }
    }

    /// Liquid Glass belongs to the panel chrome only; rows inside stay plain grouped rows.
    @ViewBuilder private var chromeBackground: some View {
        if reduceTransparency {
            shape.fill(Color(uiColor: .systemGroupedBackground))
        } else {
            Color.clear.glassEffect(.regular, in: shape)
        }
    }
}
