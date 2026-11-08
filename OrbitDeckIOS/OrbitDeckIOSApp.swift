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
    @StateObject private var autoSwitch = AutoSwitchController()
    @StateObject private var packet = PacketEngine()
    @StateObject private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase

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
                .environmentObject(autoSwitch)
                .environmentObject(packet)
                .environmentObject(liveActivity)
                .preferredColorScheme(.dark)
                .task {
                    notifications.activate()
                    rig.attach(store)
                    rotator.attach(store, autoSwitch: autoSwitch)
                    RigctldServer.shared.attach(rig)
                    RotctldServer.shared.attach(rotator)
                    audio.attach(rig)
                    qsoLog.attach()
                    recorder.attach(qsoLog)
                    sstv.attach(qsoLog)
                    ft4.attach(rig: rig, qso: qsoLog)
                    voice.attach(rig: rig, hub: audio)
                    packet.attach(rig: rig, audio: audio, store: store, qso: qsoLog)
                    await store.bootstrap()
                    // After bootstrap so the first tick sees the loaded catalog/selection.
                    autoSwitch.attach(store)
                    liveActivity.attach(store: store, autoSwitch: autoSwitch)
                }
                .onChange(of: scenePhase) { _, phase in
                    // A Live Activity can only start in the foreground.
                    if phase == .active { Task { await liveActivity.refresh() } }
                }
        }
    }
}
