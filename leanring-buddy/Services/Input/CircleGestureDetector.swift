//
//  CircleGestureDetector.swift
//  Sage
//
//  While the push-to-talk shortcut is held, the mouse works like a pen. If
//  the path closes a loop around something (roughly a circle, any size,
//  either direction), that loop is what the user is asking about.
//
//  A loop counts when the path comes back near where it started and the
//  pen's direction turns most of the way around. That rejects ordinary mouse
//  movement (lines, zigzags, hovering) while accepting sloppy, quick circles.
//

import CoreGraphics
import Foundation

/// The area the user drew a loop around, in AppKit global coordinates.
struct CircledArea: Equatable {
    /// The loop as drawn, for drawing it back on screen and on the screenshot.
    let outline: [CGPoint]
    let bounds: CGRect

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// The clean shape that replaces the hand-drawn loop: a perfect circle
    /// when the loop was roughly round, otherwise a smooth ellipse. Padded a
    /// little so the line sits around the item, not on top of it.
    var focusRect: CGRect {
        let padding = max(6, max(bounds.width, bounds.height) * 0.08)
        let paddedBounds = bounds.insetBy(dx: -padding, dy: -padding)
        let shortSide = min(paddedBounds.width, paddedBounds.height)
        let longSide = max(paddedBounds.width, paddedBounds.height)
        guard shortSide / longSide >= 0.75 else { return paddedBounds }
        return CGRect(x: paddedBounds.midX - longSide / 2, y: paddedBounds.midY - longSide / 2, width: longSide, height: longSide)
    }
}

enum CircleGestureDetector {
    /// Loops smaller than this (in points) are jitter, not a circle.
    static let minimumLoopSize: CGFloat = 24
    /// About 300 degrees: most of the way around is enough for a quick circle.
    static let minimumTurningRadians: CGFloat = 1.7 * .pi
    /// A very flat loop is a back-and-forth stroke, not a circle.
    static let minimumAspectRatio: CGFloat = 0.2
    /// Points closer together than this are merged, so hovering adds nothing.
    static let samplingSpacing: CGFloat = 4
    private static let minimumLoopPointCount = 8
    /// Only the most recent part of a long press is searched (about 3,600
    /// points of movement), which keeps the search well under a millisecond.
    private static let maximumSearchedPointCount = 900

    /// Finds the most recently completed loop in `path` (and, for that end,
    /// the largest one, so a circle drawn twice counts as one), or nil.
    ///
    /// "Turning" is the total change in the pen's direction along the path:
    /// about 2π for a full circle, near zero for lines and zigzags. Prefix
    /// sums make each loop's turning a subtraction, so the search stays fast.
    static func detectCircle(in path: [CGPoint]) -> CircledArea? {
        let points = Array(spacedOut(path).suffix(maximumSearchedPointCount))
        guard points.count >= minimumLoopPointCount else { return nil }

        // turnBeforeSegment[k] = total direction change from segment 0 up to segment k.
        var segmentHeadings: [CGFloat] = []
        for index in 0..<(points.count - 1) {
            segmentHeadings.append(atan2(points[index + 1].y - points[index].y, points[index + 1].x - points[index].x))
        }
        var turnBeforeSegment: [CGFloat] = [0]
        for index in 1..<segmentHeadings.count {
            var headingChange = segmentHeadings[index] - segmentHeadings[index - 1]
            if headingChange > .pi { headingChange -= 2 * .pi }
            if headingChange < -.pi { headingChange += 2 * .pi }
            turnBeforeSegment.append(turnBeforeSegment[index - 1] + headingChange)
        }

        for endIndex in stride(from: points.count - 1, through: minimumLoopPointCount - 1, by: -1) {
            var loopBounds = CGRect(origin: points[endIndex], size: .zero)
            var largestLoopStartIndex: Int?
            for startIndex in stride(from: endIndex - 1, through: 0, by: -1) {
                loopBounds = loopBounds.union(CGRect(origin: points[startIndex], size: .zero))
                guard endIndex - startIndex >= minimumLoopPointCount - 1 else { continue }
                let shortSide = min(loopBounds.width, loopBounds.height)
                let longSide = max(loopBounds.width, loopBounds.height)
                guard shortSide >= minimumLoopSize, shortSide / longSide >= minimumAspectRatio else { continue }
                let closingGap = hypot(points[endIndex].x - points[startIndex].x, points[endIndex].y - points[startIndex].y)
                guard closingGap <= max(20, shortSide * 0.3) else { continue }
                // Segments startIndex ..< endIndex make up the loop.
                let loopTurning = turnBeforeSegment[endIndex - 1] - turnBeforeSegment[startIndex]
                if abs(loopTurning) >= minimumTurningRadians {
                    largestLoopStartIndex = startIndex
                }
            }
            if let largestLoopStartIndex {
                let loop = Array(points[largestLoopStartIndex...endIndex])
                return CircledArea(outline: loop, bounds: boundingRect(of: loop))
            }
        }
        return nil
    }

    static func spacedOut(_ path: [CGPoint]) -> [CGPoint] {
        guard var lastKeptPoint = path.first else { return [] }
        var keptPoints = [lastKeptPoint]
        for point in path.dropFirst() where hypot(point.x - lastKeptPoint.x, point.y - lastKeptPoint.y) >= samplingSpacing {
            keptPoints.append(point)
            lastKeptPoint = point
        }
        return keptPoints
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect {
        let xValues = points.map(\.x)
        let yValues = points.map(\.y)
        let minimumX = xValues.min() ?? 0
        let minimumY = yValues.min() ?? 0
        return CGRect(x: minimumX, y: minimumY, width: (xValues.max() ?? 0) - minimumX, height: (yValues.max() ?? 0) - minimumY)
    }
}
