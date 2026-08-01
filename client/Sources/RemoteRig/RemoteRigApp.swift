import SwiftUI

@main
struct RemoteRigApp: App {
    @StateObject private var model = RemoteRigModel()

    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
