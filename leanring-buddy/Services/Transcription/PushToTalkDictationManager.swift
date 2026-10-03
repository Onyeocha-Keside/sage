//
//  PushToTalkDictationManager.swift
//  Sage
//
//  Records the microphone while the push-to-talk shortcut is held, streams
//  the audio into Apple's speech recognizer, and hands back the final
//  transcript after release. Also publishes a live audio level for the
//  waveform that replaces the cursor while you talk.
//

import AVFoundation
import Combine
import CoreGraphics
import Foundation
import os
import Speech

@MainActor
final class PushToTalkDictationManager: ObservableObject {
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizingTranscript = false
    /// 0...1, smoothed, drives the listening waveform.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var lastErrorMessage: String?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecording || isFinalizingTranscript
    }

    private let logger = Logger(subsystem: "com.kesideonyeocha.sage", category: "dictation")
    private let audioEngine = AVAudioEngine()
    private var activeTranscriptionSession: SpeechTranscriptionSession?
    private var onFinalTranscript: ((String) -> Void)?
    private var latestRecognizedText = ""
    private var hasFinishedCurrentSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    /// Changes on every start/stop so a slow start can tell it was superseded.
    private var currentStartRequestIdentifier = UUID()

    // MARK: - Warm Up

    private var hasPrewarmed = false

    /// Gets the microphone and speech recognizer ready ahead of time. Without
    /// this, the very first press freezes the app for a couple of seconds while
    /// macOS spins them up, and key presses during that freeze get jumbled.
    /// Only call once microphone permission is granted.
    func prewarmIfNeeded() {
        guard !hasPrewarmed, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        hasPrewarmed = true
        AppleSpeechTranscriber.prewarm()
        // Touching the input node sets up the audio hardware connection;
        // prepare() allocates what start() needs, without turning the mic on.
        _ = audioEngine.inputNode.outputFormat(forBus: 0)
        audioEngine.prepare()
        logger.notice("Microphone and speech recognizer prewarmed")
    }

    // MARK: - Recording

    /// Starts recording. `onFinalTranscript` is called once with the
    /// transcript after `stopRecordingAndTranscribe()`, unless nothing was said.
    func startRecording(onFinalTranscript: @escaping (String) -> Void) async {
        guard !isDictationInProgress else { return }

        let startRequestIdentifier = UUID()
        currentStartRequestIdentifier = startRequestIdentifier
        lastErrorMessage = nil

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            lastErrorMessage = "Sage needs microphone access. Grant it from the menu bar panel."
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            lastErrorMessage = "Sage needs speech recognition access. Grant it from the menu bar panel."
            return
        }

        isPreparingToRecord = true
        latestRecognizedText = ""
        hasFinishedCurrentSession = false
        self.onFinalTranscript = onFinalTranscript

        do {
            try startRecognitionSession()

            // The shortcut may have been released while the audio engine was starting.
            guard !Task.isCancelled, currentStartRequestIdentifier == startRequestIdentifier else {
                tearDownAudioAndSession()
                resetSessionState()
                return
            }

            isPreparingToRecord = false
            isRecording = true
            print("🎙️ Recording started")
            logger.notice("Recording started")
        } catch {
            print("❌ Couldn't start recording: \(error)")
            logger.error("Couldn't start recording: \(String(describing: error), privacy: .public)")
            lastErrorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            tearDownAudioAndSession()
            resetSessionState()
        }
    }

    /// Stops recording and waits for the final transcript.
    func stopRecordingAndTranscribe() {
        currentStartRequestIdentifier = UUID()

        guard isRecording else {
            isPreparingToRecord = false
            return
        }

        isRecording = false
        isFinalizingTranscript = true

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.requestFinalTranscript()

        // Safety net in case the recognizer never sends a final result.
        let fallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds ?? 1.8
        finalizeFallbackWorkItem?.cancel()
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishCurrentSessionIfNeeded()
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelaySeconds, execute: fallbackWorkItem)
    }

    /// Throws away the current recording without producing a transcript.
    func cancel() {
        currentStartRequestIdentifier = UUID()
        guard isDictationInProgress else { return }
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        tearDownAudioAndSession()
        resetSessionState()
    }

    // MARK: - Session Plumbing

    private func startRecognitionSession() throws {
        activeTranscriptionSession?.cancel()

        activeTranscriptionSession = try AppleSpeechTranscriber.startSession(
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText
                    if self.isFinalizingTranscript {
                        self.finishCurrentSessionIfNeeded()
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] audioBuffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(audioBuffer)
            self?.updateAudioPowerLevel(from: audioBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognitionError(_ error: Error) {
        guard !hasFinishedCurrentSession else { return }

        let hasUsableTranscript = !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Apple reports holding the keys in silence as error 1110. That's not
        // a failure worth showing, just treat it like a tap with nothing said.
        let isNoSpeechDetectedError = (error as NSError).code == 1110
        if isFinalizingTranscript && hasUsableTranscript {
            finishCurrentSessionIfNeeded()
        } else if isNoSpeechDetectedError {
            logger.notice("Recording finished but no speech was detected")
            cancel()
        } else {
            print("❌ Speech recognition error: \(error)")
            logger.error("Speech recognition error: \(String(describing: error), privacy: .public)")
            // Apple's recognizer refuses to run at all while macOS Dictation is
            // switched off (error 201), so point straight at the setting.
            let isDictationDisabledError = (error as NSError).code == 201
                || error.localizedDescription.localizedCaseInsensitiveContains("dictation")
            lastErrorMessage = isDictationDisabledError
                ? "Turn on Dictation in System Settings → Keyboard, then try again."
                : "Couldn't transcribe that. Try again."
            cancel()
        }
    }

    private func finishCurrentSessionIfNeeded() {
        guard !hasFinishedCurrentSession else { return }
        hasFinishedCurrentSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalTranscript = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptCallback = onFinalTranscript

        tearDownAudioAndSession()
        resetSessionState()

        guard !finalTranscript.isEmpty else {
            print("🎙️ Nothing was said")
            logger.notice("Recording finished but no speech was recognized")
            return
        }
        print("🗣️ Transcript: \(finalTranscript)")
        logger.notice("Transcript: \(finalTranscript, privacy: .public)")
        transcriptCallback?(finalTranscript)
    }

    private func tearDownAudioAndSession() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil
    }

    private func resetSessionState() {
        onFinalTranscript = nil
        latestRecognizedText = ""
        isPreparingToRecord = false
        isRecording = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
    }

    // MARK: - Audio Level

    /// Called on the audio thread for every mic buffer. Computes loudness
    /// (root mean square) and publishes a smoothed level on the main thread.
    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let firstChannelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var sumOfSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = firstChannelSamples[sampleIndex]
            sumOfSquares += sample * sample
        }

        let rootMeanSquare = sqrt(sumOfSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Rise instantly, fall gently, so the waveform doesn't flicker.
            self.currentAudioPowerLevel = max(CGFloat(boostedLevel), self.currentAudioPowerLevel * 0.72)
        }
    }
}
