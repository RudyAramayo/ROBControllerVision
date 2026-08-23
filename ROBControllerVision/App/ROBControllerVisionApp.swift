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

        WindowGroup(id: "insta360-window") {
            Insta360WindowView(model: model)
        }
        .defaultSize(width: 1_100, height: 640)

        ImmersiveSpace(id: "insta360-immersive") {
            Insta360ImmersiveView(model: model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
