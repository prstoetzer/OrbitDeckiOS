import SwiftUI

@main
struct OrbitDeckIOSApp: App {
    @StateObject private var store = OrbitStore()
    @StateObject private var notifications = NotificationRouter()
    @StateObject private var rig = RigController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notifications)
                .environmentObject(rig)
                .preferredColorScheme(.dark)
                .task {
                    notifications.activate()
                    rig.attach(store)
                    await store.bootstrap()
                }
        }
    }
}
