import Foundation

/// Sounds shipped with Smooth; system uses the device's default alarm.
enum SweeperSound: String, CaseIterable, Identifiable, Sendable {
    case smooth, chime, pulse, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .smooth: "Smooth · original"
        case .chime: "gentle chime"
        case .pulse: "classic pulse"
        case .system: "system alarm"
        }
    }
    var filename: String? {
        switch self {
        case .smooth: "berserk-alarm.caf"
        case .chime: "sweeper-chime.wav"
        case .pulse: "sweeper-pulse.wav"
        case .system: nil
        }
    }
}
