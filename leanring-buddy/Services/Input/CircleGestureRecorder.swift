//
//  CircleGestureRecorder.swift
//  Sage
//
//  Records the mouse path while the push-to-talk shortcut is held, and keeps
//  a short fading trail for the overlay to draw, so the user can see what
//  they're drawing. Only positions are kept, in memory, for one recording.
//

import AppKit
import Foundation

@MainActor
final class CircleGestureRecorder {
    /// The trail shows the last moment of movement, then fades away.
    private static let trailDurationSeconds: TimeInterval = 1.2
    private static let samplingIntervalSeconds: TimeInterval = 1.0 / 60.0

    private var fullPath: [CGPoint] = []
    private var recentPoints: [(location: CGPoint, uptime: TimeInterval)] = []
    private var samplingTimer: Timer?

    /// Called with the visible trail (AppKit global points) whenever it changes.
    var onTrailChanged: (([CGPoint]) -> Void)?

    func start() {
        stopSampling()
        fullPath = []
        recentPoints = []
        samplingTimer = Timer.scheduledTimer(withTimeInterval: Self.samplingIntervalSeconds, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this is already the main actor.
            MainActor.assumeIsolated {
                self?.sampleMouseLocation()
            }
        }
    }

    /// Stops recording and returns the whole path drawn during the press.
    func stop() -> [CGPoint] {
        stopSampling()
        let recordedPath = fullPath
        fullPath = []
        recentPoints = []
        onTrailChanged?([])
        return recordedPath
    }

    private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func sampleMouseLocation() {
        let mouseLocation = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        var trailChanged = false

        if fullPath.last.map({ hypot($0.x - mouseLocation.x, $0.y - mouseLocation.y) >= 1 }) ?? true {
            fullPath.append(mouseLocation)
            recentPoints.append((mouseLocation, now))
            trailChanged = true
        }
        let oldestVisibleUptime = now - Self.trailDurationSeconds
        if let firstVisibleIndex = recentPoints.firstIndex(where: { $0.uptime >= oldestVisibleUptime }), firstVisibleIndex > 0 {
            recentPoints.removeFirst(firstVisibleIndex)
            trailChanged = true
        } else if recentPoints.last.map({ $0.uptime < oldestVisibleUptime }) == true {
            recentPoints.removeAll()
            trailChanged = true
        }
        if trailChanged {
            onTrailChanged?(recentPoints.map(\.location))
        }
    }
}
