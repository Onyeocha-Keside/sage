import CoreGraphics
import Foundation

/// Modifier-only choices avoid inserting a character into the focused app.
/// VoiceOver's Control + Option modifier is deliberately not offered.
enum PushToTalkShortcut: String, CaseIterable {
    case controlShift
    case optionShift
    case commandShift

    static var selected: PushToTalkShortcut {
        UserDefaults.standard.string(forKey: "pushToTalkShortcut")
            .flatMap(PushToTalkShortcut.init(rawValue:)) ?? .controlShift
    }

    var displayText: String {
        switch self {
        case .controlShift: return "Control + Shift"
        case .optionShift: return "Option + Shift"
        case .commandShift: return "Command + Shift"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlShift: return [.maskControl, .maskShift]
        case .optionShift: return [.maskAlternate, .maskShift]
        case .commandShift: return [.maskCommand, .maskShift]
        }
    }

    func matches(_ eventFlags: CGEventFlags) -> Bool {
        let relevantFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        return eventFlags.intersection(relevantFlags) == flags
    }
}
