import GameController
import SwiftUI

struct ContentView: View {
    @Bindable var model: RobotViewModel
    @FocusState private var receivesControllerEvents: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            ControlPanel(model: model)
                .frame(width: 360, height: 820)
                .cockpitWing(.left)

            VideoPanel(model: model)
                .frame(width: 920)
                .shadow(color: .black.opacity(0.38), radius: 34, y: 18)
                .accessibilitySortPriority(3)

            VStack(spacing: 18) {
                ConnectionStatusView(model: model, compact: true)
                OperatorSpeechPanel(model: model)
                TelemetryPanel(snapshot: model.snapshot, layout: .vertical)
                Spacer(minLength: 0)
                CockpitSafetyLegend()
            }
            .frame(width: 360, height: 820)
            .cockpitWing(.right)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 1_760, height: 920)
        .background {
            RadialGradient(
                colors: [.cyan.opacity(0.08), .clear],
                center: .center,
                startRadius: 80,
                endRadius: 820
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Text("ROB CONTROL DECK")
                .font(.caption2.weight(.bold))
                .tracking(2.5)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .focusable()
        .focused($receivesControllerEvents)
        .task {
            receivesControllerEvents = true
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

private enum CockpitWingSide {
    case left
    case right

    var angle: Double { self == .left ? 8 : -8 }
    var anchor: UnitPoint { self == .left ? .trailing : .leading }
}

private struct CockpitWingModifier: ViewModifier {
    let side: CockpitWingSide

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(side.angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: side.anchor,
                perspective: 0.22
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
