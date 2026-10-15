//
//  ScrollActivityLog.swift
//  Sage
//
//  Remembers recent scrolling (how far, and where the mouse was) so pointing
//  targets taken from an older screenshot can be shifted to where their
//  content is now. Only scroll distances and the mouse position are kept, in
//  memory, for two minutes. Nothing about the content is read here.
//

import AppKit
import Foundation

@MainActor
final class ScrollActivityLog {
    private static let retentionSeconds: TimeInterval = 120
    /// Momentum scrolling can send over a hundred events a second; this caps memory.
    private static let maximumMovementCount = 6000

    private(set) var movements: [ScrollMovement] = []
    /// Called on the main actor after each scroll event.
    var onScroll: (() -> Void)?
    private var globalScrollMonitor: Any?

    func start() {
        guard globalScrollMonitor == nil else { return }
        // Only events aimed at other apps matter: Sage's overlay is click-through.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] scrollEvent in
            let movement = ScrollMovement(
                uptime: scrollEvent.timestamp,
                mouseLocation: NSEvent.mouseLocation,
                deltaX: scrollEvent.scrollingDeltaX,
                deltaY: scrollEvent.scrollingDeltaY,
                hasPreciseDeltas: scrollEvent.hasPreciseScrollingDeltas
            )
            Task { @MainActor [weak self] in
                self?.record(movement)
            }
        }
    }

    func stop() {
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        movements.removeAll()
    }

    private func record(_ movement: ScrollMovement) {
        guard movement.deltaX != 0 || movement.deltaY != 0 else { return }
        movements.append(movement)
        let oldestKeptUptime = movement.uptime - Self.retentionSeconds
        if let firstKeptIndex = movements.firstIndex(where: { $0.uptime >= oldestKeptUptime }), firstKeptIndex > 0 {
            movements.removeFirst(firstKeptIndex)
        }
        if movements.count > Self.maximumMovementCount {
            movements.removeFirst(movements.count - Self.maximumMovementCount)
        }
        onScroll?()
    }
}
