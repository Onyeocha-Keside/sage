//
//  SoundEffects.swift
//  Sage
//
//  Small audio cues so you can tell what Sage is doing without looking.
//  Uses sounds that ship with macOS, so there's nothing to license and
//  nothing to bundle. Can be turned off from the menu bar panel.
//

import AppKit
import Foundation

enum SoundEffect {
    /// You pressed the shortcut and Sage is listening.
    case listeningStarted
    /// You let go and your question is on its way.
    case questionSent
    /// Follow-along mode noticed you moved on and is looking at the new screen.
    case lookingAgain

    fileprivate var systemSoundName: String {
        switch self {
        case .listeningStarted: return "Tink"
        case .questionSent: return "Pop"
        case .lookingAgain: return "Bottle"
        }
    }

    /// Kept quiet so the cues feel like part of the UI, not alerts.
    fileprivate var volume: Float {
        switch self {
        case .listeningStarted: return 0.35
        case .questionSent: return 0.3
        case .lookingAgain: return 0.25
        }
    }
}

enum SoundEffectsPlayer {
    private static let soundsEnabledDefaultsKey = "areSoundEffectsEnabled"

    /// On by default.
    static var areSoundEffectsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundsEnabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundsEnabledDefaultsKey) }
    }

    static func play(_ soundEffect: SoundEffect) {
        guard areSoundEffectsEnabled,
              let systemSound = NSSound(named: NSSound.Name(soundEffect.systemSoundName))?.copy() as? NSSound else {
            return
        }
        // Copying lets the same cue overlap itself if it's triggered twice quickly.
        systemSound.volume = soundEffect.volume
        systemSound.play()
    }
}
