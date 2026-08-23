import GameController
import SwiftUI

struct ContentView: View {
    @Bindable var model: RobotViewModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @FocusState private var receivesControllerEvents: Bool

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 1_400 {
                    wideDeck(size: geometry.size)
                } else {
                    compactDeck
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RadialGradient(
                    colors: [.cyan.opacity(0.08), .clear],
                    center: .center,
                    startRadius: 80,
                    endRadius: 820
                )
                .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 760, idealWidth: 1_760, minHeight: 620, idealHeight: 920)
        .overlay(alignment: .top) {
            Text("ROB CONTROL DECK")
                .font(.caption2.weight(.bold))
                .tracking(2.5)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .allowsHitTesting(false)
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .focusable()
        .focused($receivesControllerEvents)
        .onAppear {
            receivesControllerEvents = true
        }
        #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("--immersive-smoke-test") {
                    _ = await openImmersiveSpace(id: "insta360-immersive")
                }
            }
        #endif
    }

    private func wideDeck(size: CGSize) -> some View {
        let sideWidth = min(360, max(300, size.width * 0.205))

        return HStack(alignment: .center, spacing: 22) {
            panelScroll {
                ControlPanel(model: model)
            }
            .frame(width: sideWidth)
            .cockpitWing(.left)

            panelScroll {
                VideoPanel(model: model)
            }
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.38), radius: 34, y: 18)
            .accessibilitySortPriority(3)

            panelScroll {
                rightPanelContent
            }
            .frame(width: sideWidth)
            .cockpitWing(.right)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }

    private var compactDeck: some View {
        ScrollView(.vertical) {
            VStack(spacing: 18) {
                ConnectionStatusView(model: model)
                VideoPanel(model: model)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ControlPanel(model: model)
                            .frame(minWidth: 360, maxWidth: .infinity)
                        VStack(spacing: 18) {
                            OperatorSpeechPanel(model: model)
                            TelemetryPanel(snapshot: model.snapshot, layout: .vertical)
                            CockpitSafetyLegend()
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)
                    }

                    VStack(spacing: 18) {
                        ControlPanel(model: model)
                        OperatorSpeechPanel(model: model)
                        TelemetryPanel(snapshot: model.snapshot, layout: .vertical)
                        CockpitSafetyLegend()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .scrollIndicators(.visible)
    }

    private var rightPanelContent: some View {
        VStack(spacing: 18) {
            ConnectionStatusView(model: model, compact: true)
            OperatorSpeechPanel(model: model)
            TelemetryPanel(snapshot: model.snapshot, layout: .vertical)
            CockpitSafetyLegend()
        }
    }

    private func panelScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
    }
}

private enum CockpitWingSide {
    case left
    case right

    var angle: Double { self == .left ? 8 : -8 }
    var anchor: UnitPoint3D { self == .left ? .trailing : .leading }
}

private struct CockpitWingModifier: ViewModifier {
    let side: CockpitWingSide

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(side.angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: side.anchor
            )
            .offset(z: 42)
            .shadow(color: .black.opacity(0.42), radius: 30, y: 18)
    }
}

private extension View {
    func cockpitWing(_ side: CockpitWingSide) -> some View {
        modifier(CockpitWingModifier(side: side))
    }
}

private struct CockpitSafetyLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("SPATIAL CONTROL DECK", systemImage: "visionpro")
                .font(.caption.bold())
                .foregroundStyle(.cyan)
            Text("Camera stays forward. Controls wrap inward but remain screen-space interfaces; controller poses never bypass arming, freshness, or the physical emergency stop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Material.thin)
        )
    }
}
