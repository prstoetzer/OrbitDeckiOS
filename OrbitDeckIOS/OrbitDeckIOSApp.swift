import SwiftUI

@main
struct OrbitDeckIOSApp: App {
    @StateObject private var store = OrbitStore()
    @StateObject private var notifications = NotificationRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notifications)
                .preferredColorScheme(.dark)
                .task {
                    notifications.activate()
                    await store.bootstrap()
                }
        }
    }
}
