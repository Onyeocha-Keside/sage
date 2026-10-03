//
//  AppleSpeechVoice.swift
//  Sage
//
//  The free voice: macOS's built-in speech synthesizer. It runs on the Mac,
//  costs nothing, and works offline.
//
//  Tip: the default voices sound robotic. Download a Premium voice in
//  System Settings → Accessibility → Spoken Content → System Voice →
//  Manage Voices (for example "Zoe (Premium)" or "Ava (Premium)").
//  Sage automatically picks the highest-quality English voice installed.
//

import AVFoundation
import Foundation

final class AppleSpeechVoice: NSObject, SpeechVoice, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let chosenSystemVoice = AppleSpeechVoice.highestQualityEnglishVoice()

    /// Resumed when the current utterance finishes or is cancelled.
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    /// Identifies the utterance the continuation belongs to, so a late
    /// "cancelled" callback from an older utterance can't end a newer one.
    private var currentUtteranceIdentifier: ObjectIdentifier?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        if let chosenSystemVoice {
            print("🔊 Mac voice: \(chosenSystemVoice.name) (\(chosenSystemVoice.language))")
        }
    }

    func prepare(_ text: String) -> PreparedSpeech {
        // Nothing to download. Synthesis happens on the Mac at play time.
        PreparedSpeech(text: text, audioDownloadTask: nil)
    }

    func play(_ preparedSpeech: PreparedSpeech, onPlaybackStarted: () -> Void) async throws {
        stopPlayback()

        let utterance = AVSpeechUtterance(string: preparedSpeech.text)
        utterance.voice = chosenSystemVoice

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playbackContinuation = continuation
                currentUtteranceIdentifier = ObjectIdentifier(utterance)
                speechSynthesizer.speak(utterance)
                onPlaybackStarted()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stopPlayback()
            }
        }
    }

    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        finishPlayback(throwing: CancellationError())
    }

    private func finishPlayback(throwing playbackError: Error?) {
        guard let playbackContinuation else { return }
        self.playbackContinuation = nil
        currentUtteranceIdentifier = nil
        if let playbackError {
            playbackContinuation.resume(throwing: playbackError)
        } else {
            playbackContinuation.resume()
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedUtteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.currentUtteranceIdentifier == finishedUtteranceIdentifier else { return }
            self.finishPlayback(throwing: nil)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledUtteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.currentUtteranceIdentifier == cancelledUtteranceIdentifier else { return }
            self.finishPlayback(throwing: CancellationError())
        }
    }

    // MARK: - Voice Selection

    /// Picks the best English voice installed: Premium over Enhanced over
    /// Default, preferring the user's own English region (en-US, en-GB, ...).
    /// Novelty voices like "Bells" or "Bad News" are skipped.
    private static func highestQualityEnglishVoice() -> AVSpeechSynthesisVoice? {
        let preferredLanguageCode = AVSpeechSynthesisVoice.currentLanguageCode()

        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en") && !voice.voiceTraits.contains(.isNoveltyVoice)
        }

        let bestVoice = englishVoices.max { firstVoice, secondVoice in
            if firstVoice.quality != secondVoice.quality {
                return firstVoice.quality.rawValue < secondVoice.quality.rawValue
            }
            let firstMatchesUserRegion = firstVoice.language == preferredLanguageCode
            let secondMatchesUserRegion = secondVoice.language == preferredLanguageCode
            return !firstMatchesUserRegion && secondMatchesUserRegion
        }

        return bestVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
