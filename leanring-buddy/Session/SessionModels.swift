import Foundation

enum SessionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Which voice Sage speaks with. Persisted across launches.
enum SageVoiceOption: String, CaseIterable, Identifiable {
    /// macOS's built-in voice. Free.
    case mac
    /// ElevenLabs through the Worker. Sounds great, costs credits.
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .elevenLabs: return "ElevenLabs"
        }
    }
}

