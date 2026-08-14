import SwiftUI

@main
struct RemoteRigApp: App {
    @StateObject private var model = RemoteRigModel()

    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.automatic)
        .defaultSize(width: 520, height: 700)
    }
}
