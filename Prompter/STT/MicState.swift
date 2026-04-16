import Foundation

/// Thread-safe mutable mute state shared across STT engines.
final class MicState {
    static let shared = MicState()

    private let lock = NSLock()
    private var _isMuted: Bool = false

    var isMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMuted
        }
        set {
            lock.lock()
            _isMuted = newValue
            lock.unlock()
        }
    }

    private init() {}
}
