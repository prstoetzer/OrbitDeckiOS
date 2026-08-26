import SwiftUI

@main
struct OrbitDeckIOSApp: App {
    @StateObject private var store = OrbitStore()
    @StateObject private var notifications = NotificationRouter()
    @StateObject private var rig = RigController()
    @StateObject private var rotator = RotatorController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notifications)
                .environmentObject(rig)
                .environmentObject(rotator)
                .preferredColorScheme(.dark)
                .task {
                    notifications.activate()
                    rig.attach(store)
                    rotator.attach(store)
                    await store.bootstrap()
                }
        }
    }
}
