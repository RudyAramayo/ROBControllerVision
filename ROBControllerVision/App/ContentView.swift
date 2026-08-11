import GameController
import SwiftUI

struct ContentView: View {
    @Bindable var model: RobotViewModel

    var body: some View {
        VStack(spacing: 18) {
            ConnectionStatusView(model: model)

            VideoPanel(model: model)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 20) {
                ControlPanel(model: model)
                    .frame(width: 480)

                TelemetryPanel(snapshot: model.snapshot)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(minWidth: 1_280, minHeight: 900)
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}
