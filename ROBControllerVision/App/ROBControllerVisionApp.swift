import SwiftUI

@main
@MainActor
struct ROBControllerVisionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RobotViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 1_760, height: 920)
        // Read scenePhase at the App/Scene level so it represents all windows
        // and the immersive space together. A window disappearing must not
        // tear down video while the immersive scene remains active.
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            model.start()
            switch newPhase {
            case .active:
                model.setSceneActive(true)
            case .inactive:
                // An immersive transition commonly makes the presenting
                // window inactive. Brake motion, but retain video and its
                // negotiated subscription for the immersive scene.
                model.setSceneActive(false, preservingVideo: true)
            case .background:
                model.setSceneActive(false)
            @unknown default:
                model.setSceneActive(false)
            }
        }

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
