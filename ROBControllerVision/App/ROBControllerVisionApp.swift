import SwiftUI

@main
@MainActor
struct ROBControllerVisionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RobotViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    model.setSceneActive(newPhase == .active)
                }
        }
        .defaultSize(width: 1_760, height: 920)
        .windowResizability(.contentSize)
    }
}
