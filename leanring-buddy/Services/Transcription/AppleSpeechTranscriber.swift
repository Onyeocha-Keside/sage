//
//  AppleSpeechTranscriber.swift
//  Sage
//
//  Free speech-to-text using Apple's Speech framework. On Apple Silicon Macs
//  recognition runs fully on-device, so nothing you say leaves the machine
//  until Sage sends the final transcript to Claude.
//

import AVFoundation
import Foundation
import Speech

struct SpeechTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppleSpeechTranscriber {
    /// Words the recognizer should expect, so app and product names
    /// come out spelled right.
    private static let contextualVocabulary = [
        "Sage", "Claude", "Xcode", "SwiftUI", "VS Code", "Figma", "Notion",
        "GitHub", "Terminal", "Finder", "Safari", "Chrome", "localhost",
        // Cloud and developer terms that are easy to mishear ("ECR" → "ER").
        "AWS", "ECR", "ECS", "EC2", "S3", "IAM", "Lambda", "CloudWatch",
        "Docker", "Kubernetes", "npm", "API", "JSON", "SQL", "Postgres", "Vercel"
    ]

    /// Created once and reused. Building a recognizer loads speech models,
    /// which is slow enough to notice on the first press if done on demand.
    private static var sharedSpeechRecognizer: SFSpeechRecognizer?

    /// Loads the recognizer ahead of time so the first push-to-talk is instant.
    static func prewarm() {
        if sharedSpeechRecognizer == nil {
            sharedSpeechRecognizer = makeBestAvailableSpeechRecognizer()
        }
    }

    static func startSession(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws -> SpeechTranscriptionSession {
        prewarm()
        guard let speechRecognizer = sharedSpeechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechTranscriptionError(message: "Speech recognition isn't available on this Mac right now.")
        }

        return SpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            contextualVocabulary: contextualVocabulary,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    private static func makeBestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
}

/// One push-to-talk recording: audio goes in while the shortcut is held,
/// and the final transcript comes out after release.
final class SpeechTranscriptionSession: NSObject {
    /// If Apple never sends a "final" result, Sage uses the latest partial
    /// transcript after this long.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        contextualVocabulary: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        super.init()

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        recognitionRequest.contextualStrings = contextualVocabulary
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        recognitionRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        recognitionRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func handleRecognitionEvent(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestRecognizedText = result.bestTranscription.formattedString
            onTranscriptUpdate(latestRecognizedText)

            if result.isFinal {
                deliverFinalTranscriptIfNeeded(latestRecognizedText)
                return
            }
        }

        guard let error else { return }

        // Apple often reports an error right after endAudio() even though the
        // transcript is fine. If we have text, treat it as the final result.
        if hasRequestedFinalTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinalTranscriptIfNeeded(latestRecognizedText)
        } else {
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        recognitionTask?.cancel()
    }
}
