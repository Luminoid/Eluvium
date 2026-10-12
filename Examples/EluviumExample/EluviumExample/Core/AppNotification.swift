import Foundation

/// The app's cross-screen notification names.
nonisolated enum AppNotification {
    /// Relayed from `UIApplication.didReceiveMemoryWarningNotification` by
    /// the AppDelegate so feature screens can shed accumulated state
    /// (`CatalogsViewController` drops its walked pages on it).
    static let memoryWarningReceived = NSNotification.Name("EluviumExampleMemoryWarning")
    /// Posted by `AudioPlayer` on every state change; any number of player
    /// bars observe it and pull the shared state, so screens never fight
    /// over a single callback slot.
    static let audioStateChanged = NSNotification.Name("EluviumExampleAudioStateChanged")
}
