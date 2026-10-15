//
//  ReplyLatencyTimeline.swift
//  Sage
//
//  Measures the silence between the user finishing and Sage's first sound,
//  split by stage, so speed work targets the stage that's actually slow.
//  Logged once per reply; watch it with:
//    /usr/bin/log stream --predicate 'subsystem == "com.kesideonyeocha.sage" && category == "latency"'
//

import Foundation

struct ReplyLatencyTimeline {
    enum Milestone: String {
        case transcriptReady = "transcript"
        case screensCaptured = "screens"
        case predictedPointShown = "early point"
        case firstTextReceived = "first text"
        case firstChunkReady = "first chunk"
        case firstAudioStarted = "first audio"
    }

    /// What the times are measured from, like "key release".
    let startingPoint: String
    private let startInstant = ContinuousClock.now
    private(set) var millisecondsByMilestone: [(milestone: Milestone, milliseconds: Int)] = []

    init(startingPoint: String) {
        self.startingPoint = startingPoint
    }

    /// Records the first time each milestone is reached; later repeats are ignored.
    mutating func mark(_ milestone: Milestone) {
        guard !millisecondsByMilestone.contains(where: { $0.milestone == milestone }) else { return }
        let elapsed = ContinuousClock.now - startInstant
        let milliseconds = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        millisecondsByMilestone.append((milestone, milliseconds))
    }

    /// For example: "after key release: transcript 320ms, screens 280ms, first text 1450ms, …"
    var summary: String {
        let stages = millisecondsByMilestone.map { "\($0.milestone.rawValue) \($0.milliseconds)ms" }
        return "after \(startingPoint): " + stages.joined(separator: ", ")
    }
}
