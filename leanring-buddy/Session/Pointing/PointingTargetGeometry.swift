//
//  PointingTargetGeometry.swift
//  Sage
//
//  The math that keeps a pointing target attached to the content it was on
//  when that content scrolls. A target starts as a position in a screenshot
//  taken seconds earlier; if the user has scrolled since, that position now
//  shows something else. These pure functions shift a target by the scrolling
//  that happened over it and decide whether it's still visible.
//

import CoreGraphics
import Foundation

/// One scroll-wheel or trackpad event, reduced to what pointing needs.
struct ScrollMovement: Equatable {
    /// Seconds since boot, the same clock as `NSEvent.timestamp`.
    let uptime: TimeInterval
    /// Mouse location in AppKit global coordinates; content under it is what scrolled.
    let mouseLocation: CGPoint
    /// AppKit scrolling deltas: positive Y moves content down the screen,
    /// positive X moves it right.
    let deltaX: CGFloat
    let deltaY: CGFloat
    /// Trackpads and Magic Mice report exact points. Classic wheels report
    /// lines, which each app turns into a different number of points.
    let hasPreciseDeltas: Bool
}

/// Which way the user needs to scroll to bring a target back into view.
enum OffScreenEdge: Equatable {
    case above, below, left, right

    /// How the bubble tells the user which way to go.
    var scrollInstruction: String {
        switch self {
        case .above: return "scroll up"
        case .below: return "scroll down"
        case .left: return "scroll left"
        case .right: return "scroll right"
        }
    }

    /// Cursor triangle rotation that points toward the hidden target. The
    /// triangle's tip points up at zero degrees.
    var cursorRotationDegrees: Double {
        switch self {
        case .above: return 0
        case .below: return 180
        case .left: return -90
        case .right: return 90
        }
    }
}

enum PointingTargetGeometry {
    /// How far inside the visible region an off-screen target's stand-in is parked.
    static let offScreenParkingInset: CGFloat = 28

    /// How far content inside `scrollRegion` has moved since `uptime`, in
    /// AppKit coordinates. `hasImpreciseMovement` is true when any of that
    /// scrolling came from a line-based wheel, whose point distance is a guess.
    static func contentShift(from movements: [ScrollMovement], after uptime: TimeInterval,
                             within scrollRegion: CGRect) -> (shift: CGVector, hasImpreciseMovement: Bool) {
        var shift = CGVector.zero
        var hasImpreciseMovement = false
        for movement in movements where movement.uptime > uptime && scrollRegion.contains(movement.mouseLocation) {
            // AppKit's Y axis points up, so content moving down the screen lowers its Y.
            shift.dx += movement.deltaX
            shift.dy -= movement.deltaY
            if !movement.hasPreciseDeltas && (movement.deltaX != 0 || movement.deltaY != 0) {
                hasImpreciseMovement = true
            }
        }
        return (shift, hasImpreciseMovement)
    }

    /// Where to point for a target at `location`. Inside the visible region
    /// it's the location itself. Outside, the cursor parks just inside the
    /// nearest edge and says which way to scroll.
    static func placement(of location: CGPoint, within visibleRegion: CGRect) -> (location: CGPoint, offScreenEdge: OffScreenEdge?) {
        guard !visibleRegion.isNull, !visibleRegion.isEmpty, !visibleRegion.contains(location) else {
            return (location, nil)
        }
        let offScreenEdge: OffScreenEdge
        if location.y > visibleRegion.maxY {
            offScreenEdge = .above
        } else if location.y < visibleRegion.minY {
            offScreenEdge = .below
        } else if location.x < visibleRegion.minX {
            offScreenEdge = .left
        } else {
            offScreenEdge = .right
        }
        let parkingRegion = visibleRegion.insetBy(dx: min(offScreenParkingInset, visibleRegion.width / 2),
                                                  dy: min(offScreenParkingInset, visibleRegion.height / 2))
        let parkedLocation = CGPoint(x: min(max(location.x, parkingRegion.minX), parkingRegion.maxX),
                                     y: min(max(location.y, parkingRegion.minY), parkingRegion.maxY))
        return (parkedLocation, offScreenEdge)
    }

    /// Quartz and Accessibility use a top-left origin at the primary display;
    /// AppKit uses a bottom-left origin. The conversion is its own inverse.
    static func flipBetweenTopLeftAndAppKit(_ point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    static func flipBetweenTopLeftAndAppKit(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryDisplayHeight - rect.origin.y - rect.height,
               width: rect.width, height: rect.height)
    }
}
