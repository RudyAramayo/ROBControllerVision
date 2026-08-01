import GameController
import SwiftUI

struct ContentView: View {
    @Bindable var model: RobotViewModel

    var body: some View {
        VStack(spacing: 18) {
            ConnectionStatusView(model: model)

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    VideoPanel(model: model)
                    TelemetryPanel(snapshot: model.snapshot)
                }
                .frame(maxWidth: .infinity)

                ControlPanel(model: model)
                    .frame(width: 360)
            }
        }
        .padding(24)
        .frame(minWidth: 960, minHeight: 640)
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}
