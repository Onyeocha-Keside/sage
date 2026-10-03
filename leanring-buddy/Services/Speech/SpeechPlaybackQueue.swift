//
//  SpeechPlaybackQueue.swift
//  Sage
//
//  Plays reply sentences one after another, in order, while Claude is still
//  writing the rest. Reports when each sentence starts playing so the cursor
//  can fly to an element right as Sage starts talking about it.
//
//  If the chosen voice fails on a sentence (for example ElevenLabs is out of
//  credits), that sentence is spoken with the free Mac voice instead, so a
//  reply never goes silent.
//

import Foundation

@MainActor
final class SpeechPlaybackQueue {
    /// Fires with a sentence's ID the moment that sentence starts playing.
    var onSegmentStartedPlaying: ((UUID) -> Void)?

    /// True while anything is playing or waiting to play.
    var isPlaying: Bool { playbackLoopTask != nil }

    private struct QueuedSentence {
        let segmentID: UUID
        let preparedSpeech: PreparedSpeech
        let voice: SpeechVoice
    }

    private let fallbackVoice: SpeechVoice
    private var queuedSentences: [QueuedSentence] = []
    private var playbackLoopTask: Task<Void, Never>?
    private var currentlyPlayingVoice: SpeechVoice?

    init(fallbackVoice: SpeechVoice) {
        self.fallbackVoice = fallbackVoice
    }

    /// Adds a sentence to the end of the queue. Its audio starts preparing immediately.
    func enqueue(text: String, segmentID: UUID, voice: SpeechVoice) {
        queuedSentences.append(QueuedSentence(
            segmentID: segmentID,
            preparedSpeech: voice.prepare(text),
            voice: voice
        ))
        startPlaybackLoopIfNeeded()
    }

    /// Stops the current sentence and throws away everything queued.
    func stopAll() {
        for queuedSentence in queuedSentences {
            queuedSentence.preparedSpeech.cancelPreparation()
        }
        queuedSentences.removeAll()

        playbackLoopTask?.cancel()
        playbackLoopTask = nil

        currentlyPlayingVoice?.stopPlayback()
        currentlyPlayingVoice = nil
    }

    /// Waits until every queued sentence has played (or the caller is cancelled).
    func waitUntilFinishedPlaying() async {
        while isPlaying && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startPlaybackLoopIfNeeded() {
        guard playbackLoopTask == nil else { return }
        playbackLoopTask = Task { [weak self] in
            await self?.playQueuedSentencesUntilEmpty()
        }
    }

    private func playQueuedSentencesUntilEmpty() async {
        while !queuedSentences.isEmpty && !Task.isCancelled {
            let nextSentence = queuedSentences.removeFirst()
            await play(nextSentence)
        }

        // A cancelled loop may already have been replaced by a newer one
        // (stopAll followed by enqueue), so only a loop that ran to the end
        // clears the handle.
        if !Task.isCancelled {
            playbackLoopTask = nil
        }
    }

    private func play(_ queuedSentence: QueuedSentence) async {
        let segmentID = queuedSentence.segmentID
        currentlyPlayingVoice = queuedSentence.voice
        defer { currentlyPlayingVoice = nil }

        do {
            try await queuedSentence.voice.play(queuedSentence.preparedSpeech) {
                onSegmentStartedPlaying?(segmentID)
            }
        } catch is CancellationError {
            return
        } catch {
            print("⚠️ Speech failed, using the Mac voice for this sentence: \(error.localizedDescription)")
            guard queuedSentence.voice !== fallbackVoice, !Task.isCancelled else { return }

            currentlyPlayingVoice = fallbackVoice
            let fallbackSpeech = fallbackVoice.prepare(queuedSentence.preparedSpeech.text)
            try? await fallbackVoice.play(fallbackSpeech) {
                onSegmentStartedPlaying?(segmentID)
            }
        }
    }
}
