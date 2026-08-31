import SwiftUI

@main
struct OrbitDeckIOSApp: App {
    @StateObject private var store = OrbitStore()
    @StateObject private var notifications = NotificationRouter()
    @StateObject private var rig = RigController()
    @StateObject private var rotator = RotatorController()
    @StateObject private var audio = AudioHub()
    @StateObject private var qsoLog = QSOStore()
    @StateObject private var recorder = PassRecorder()
    @StateObject private var sstv = SSTVDecoder()
    @StateObject private var ft4 = FT4Engine()
    @StateObject private var voice = RemoteVoiceController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notifications)
                .environmentObject(rig)
                .environmentObject(rotator)
                .environmentObject(audio)
                .environmentObject(qsoLog)
                .environmentObject(recorder)
                .environmentObject(sstv)
                .environmentObject(ft4)
                .environmentObject(voice)
                .preferredColorScheme(.dark)
                .task {
                    notifications.activate()
                    rig.attach(store)
                    rotator.attach(store)
                    audio.attach(rig)
                    qsoLog.attach()
                    recorder.attach(qsoLog)
                    sstv.attach(qsoLog)
                    ft4.attach(rig: rig, qso: qsoLog)
                    voice.attach(rig: rig, hub: audio)
                    await store.bootstrap()
                }
        }
    }
}
