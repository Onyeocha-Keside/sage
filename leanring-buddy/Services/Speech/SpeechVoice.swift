//
//  SpeechVoice.swift
//  Sage
//
//  The shared shape of every voice Sage can talk with. Sage speaks its reply
//  one sentence at a time, so a voice gets each sentence ready early
//  (`prepare`) and plays it later, in order (`play`).
//

import Foundation

/// A sentence a voice has started getting ready to say. For network voices
/// the audio download starts when this is created, so by the time earlier
/// sentences finish playing, this one is already downloaded.
final class PreparedSpeech {
    let text: String
    /// Nil for voices that synthesize on the Mac and need no download.
    let audioDownloadTask: Task<Data, Error>?

    init(text: String, audioDownloadTask: Task<Data, Error>?) {
        self.text = text
        self.audioDownloadTask = audioDownloadTask
    }

    func cancelPreparation() {
        audioDownloadTask?.cancel()
    }
}

@MainActor
protocol SpeechVoice: AnyObject {
    /// Starts any slow work (like downloading audio) and returns immediately.
    func prepare(_ text: String) -> PreparedSpeech

    /// Plays the sentence and returns once it has finished playing.
    /// Calls `onPlaybackStarted` the moment sound starts. Throws
    /// `CancellationError` if playback is stopped early.
    func play(_ preparedSpeech: PreparedSpeech, onPlaybackStarted: () -> Void) async throws

    /// Stops whatever is playing right now.
    func stopPlayback()
}
