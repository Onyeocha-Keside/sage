//
//  ElevenLabsSpeechVoice.swift
//  Sage
//
//  The premium voice: ElevenLabs text-to-speech through the Sage Worker's
//  /tts route. Each sentence's audio starts downloading as soon as Claude
//  finishes writing it, so playback flows from one sentence to the next.
//
//  Costs ElevenLabs credits. If a request fails (no credits, Worker not
//  configured), SpeechPlaybackQueue falls back to the free Mac voice.
//

import AVFoundation
import Foundation

struct ElevenLabsSpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ElevenLabsSpeechVoice: NSObject, SpeechVoice, AVAudioPlayerDelegate {
    private let urlSession: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 40
        sessionConfiguration.urlCache = nil
        self.urlSession = URLSession(configuration: sessionConfiguration)
        super.init()
    }

    func prepare(_ text: String) -> PreparedSpeech {
        let audioDownloadTask = Task { [weak self] () throws -> Data in
            guard let self else { throw CancellationError() }
            return try await self.downloadAudio(for: text)
        }
        return PreparedSpeech(text: text, audioDownloadTask: audioDownloadTask)
    }

    func play(_ preparedSpeech: PreparedSpeech, onPlaybackStarted: () -> Void) async throws {
        guard let audioDownloadTask = preparedSpeech.audioDownloadTask else {
            throw ElevenLabsSpeechError(message: "No audio was prepared for this sentence.")
        }

        let audioData = try await withTaskCancellationHandler {
            try await audioDownloadTask.value
        } onCancel: {
            audioDownloadTask.cancel()
        }
        try Task.checkCancellation()

        let newAudioPlayer = try AVAudioPlayer(data: audioData)
        newAudioPlayer.delegate = self

        let playerIdentifier = ObjectIdentifier(newAudioPlayer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                stopPlayback()
                playbackContinuation = continuation
                audioPlayer = newAudioPlayer

                if newAudioPlayer.play() {
                    onPlaybackStarted()
                } else {
                    finishPlayback(throwing: ElevenLabsSpeechError(message: "Couldn't start audio playback."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let currentPlayer = self.audioPlayer,
                      ObjectIdentifier(currentPlayer) == playerIdentifier else { return }
                self.stopPlayback()
            }
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        // AVAudioPlayer doesn't call its delegate when stopped manually,
        // so end the waiting play() call here.
        finishPlayback(throwing: CancellationError())
    }

    private func downloadAudio(for text: String) async throws -> Data {
        var textToSpeechRequest = try AppConfiguration.makeWorkerRequest(path: "tts")
        textToSpeechRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        textToSpeechRequest.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (audioData, response) = try await urlSession.data(for: textToSpeechRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsSpeechError(message: "The Worker sent back something that isn't HTTP.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: audioData, encoding: .utf8) ?? "unknown error"
            throw ElevenLabsSpeechError(message: "ElevenLabs via Worker failed (\(httpResponse.statusCode)): \(errorBody)")
        }
        return audioData
    }

    private func finishPlayback(throwing playbackError: Error?) {
        guard let playbackContinuation else { return }
        self.playbackContinuation = nil
        if let playbackError {
            playbackContinuation.resume(throwing: playbackError)
        } else {
            playbackContinuation.resume()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayerIdentifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self,
                  let currentAudioPlayer = self.audioPlayer,
                  ObjectIdentifier(currentAudioPlayer) == finishedPlayerIdentifier else { return }
            self.audioPlayer = nil
            self.finishPlayback(throwing: nil)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failedPlayerIdentifier = ObjectIdentifier(player)
        let decodeErrorDescription = error?.localizedDescription ?? "unknown decode error"
        Task { @MainActor [weak self] in
            guard let self,
                  let currentAudioPlayer = self.audioPlayer,
                  ObjectIdentifier(currentAudioPlayer) == failedPlayerIdentifier else { return }
            self.audioPlayer = nil
            self.finishPlayback(throwing: ElevenLabsSpeechError(message: "Audio decode failed: \(decodeErrorDescription)"))
        }
    }
}
