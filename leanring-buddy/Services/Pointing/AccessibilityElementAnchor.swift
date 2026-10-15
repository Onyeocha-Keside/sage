//
//  AccessibilityElementAnchor.swift
//  Sage
//
//  Ties a pointing target to the actual on-screen control (through the macOS
//  Accessibility API) instead of a pixel position. When the content scrolls
//  or the window moves, the control's live frame says exactly where it went,
//  and its scroll area says whether it's still visible.
//
//  Works out of the box for native Mac apps and Safari. Chrome and Electron
//  apps only build their accessibility tree when asked, so the first anchor
//  attempt in those apps asks (AXManualAccessibility), which is the switch
//  Electron documents for assistive tools.
//

import AppKit
import ApplicationServices
import Foundation

/// The topmost ordinary window at a point, from another app.
struct WindowUnderPoint {
    let processID: pid_t
    /// AppKit global coordinates.
    let bounds: CGRect

    /// Sage's own overlay windows sit above everything, so they're skipped.
    static func topmostWindow(at appKitLocation: CGPoint) -> WindowUnderPoint? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let sageProcessID = ProcessInfo.processInfo.processIdentifier
        // The list is ordered front to back.
        for windowInfo in windowInfoList {
            guard let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerProcessID != sageProcessID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int, windowLayer == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let topLeftBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            let appKitBounds = PointingTargetGeometry.flipBetweenTopLeftAndAppKit(topLeftBounds, primaryDisplayHeight: primaryDisplayHeight)
            if appKitBounds.contains(appKitLocation) {
                return WindowUnderPoint(processID: ownerProcessID, bounds: appKitBounds)
            }
        }
        return nil
    }
}

@MainActor
struct AccessibilityElementAnchor {
    /// A hung app must not freeze Sage's main thread for long.
    private static let messagingTimeoutSeconds: Float = 0.1
    /// Elements this big are containers (a whole page or pane), not a control.
    private static let maximumShareOfWindowArea: CGFloat = 0.25
    private static let containerRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXScrollArea", "AXWebArea", "AXSplitGroup", "AXLayoutArea"
    ]
    private static var processIDsAskedForAccessibilityTree: Set<pid_t> = []

    private let element: AXUIElement
    private let enclosingScrollArea: AXUIElement?
    /// Where the target sits inside the element (0...1 on each axis), so Sage
    /// keeps pointing at the same spot within a wide control.
    private let relativePositionInElement: CGPoint

    /// Finds the control at `appKitLocation` in the app owning `window`.
    /// Returns nil when there's no specific control there to hold on to.
    static func make(at appKitLocation: CGPoint, in window: WindowUnderPoint) -> AccessibilityElementAnchor? {
        let applicationElement = AXUIElementCreateApplication(window.processID)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutSeconds)

        if let anchor = makeIfUseful(applicationElement: applicationElement, at: appKitLocation, windowBounds: window.bounds) {
            return anchor
        }
        // Chromium-based apps answer with one big web area until asked to
        // build their full tree. Ask once per app, then try again.
        guard !processIDsAskedForAccessibilityTree.contains(window.processID) else { return nil }
        processIDsAskedForAccessibilityTree.insert(window.processID)
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return makeIfUseful(applicationElement: applicationElement, at: appKitLocation, windowBounds: window.bounds)
    }

    private static func makeIfUseful(applicationElement: AXUIElement, at appKitLocation: CGPoint,
                                     windowBounds: CGRect) -> AccessibilityElementAnchor? {
        let topLeftLocation = PointingTargetGeometry.flipBetweenTopLeftAndAppKit(appKitLocation, primaryDisplayHeight: primaryDisplayHeight)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(applicationElement, Float(topLeftLocation.x), Float(topLeftLocation.y), &hitElement) == .success,
              let hitElement else { return nil }
        AXUIElementSetMessagingTimeout(hitElement, messagingTimeoutSeconds)

        guard let role = stringAttribute(kAXRoleAttribute, of: hitElement), !containerRoles.contains(role),
              let elementFrame = appKitFrame(of: hitElement), elementFrame.width > 0, elementFrame.height > 0,
              elementFrame.width * elementFrame.height <= windowBounds.width * windowBounds.height * maximumShareOfWindowArea,
              elementFrame.insetBy(dx: -4, dy: -4).contains(appKitLocation) else { return nil }

        let relativePosition = CGPoint(
            x: min(max((appKitLocation.x - elementFrame.minX) / elementFrame.width, 0), 1),
            y: min(max((appKitLocation.y - elementFrame.minY) / elementFrame.height, 0), 1)
        )
        return AccessibilityElementAnchor(element: hitElement,
                                          enclosingScrollArea: nearestScrollAreaAncestor(of: hitElement),
                                          relativePositionInElement: relativePosition)
    }

    /// The anchored spot right now, in AppKit coordinates. Nil once the
    /// control is gone (the page changed, the view was rebuilt).
    func currentLocation() -> CGPoint? {
        guard let elementFrame = Self.appKitFrame(of: element) else { return nil }
        return CGPoint(x: elementFrame.minX + elementFrame.width * relativePositionInElement.x,
                       y: elementFrame.minY + elementFrame.height * relativePositionInElement.y)
    }

    /// The part of the screen where the control can be seen: its scroll area's frame.
    func currentVisibleRegion() -> CGRect? {
        enclosingScrollArea.flatMap(Self.appKitFrame(of:))
    }

    // MARK: - Accessibility Reading

    private static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func nearestScrollAreaAncestor(of element: AXUIElement) -> AXUIElement? {
        var currentElement = element
        // Real hierarchies are rarely deeper than this; the cap guards against cycles.
        for _ in 0..<30 {
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
            let parentElement = parentValue as! AXUIElement
            if stringAttribute(kAXRoleAttribute, of: parentElement) == "AXScrollArea" { return parentElement }
            currentElement = parentElement
        }
        return nil
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return attributeValue as? String
    }

    private static func appKitFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = axValueAttribute(kAXPositionAttribute, of: element),
              let sizeValue = axValueAttribute(kAXSizeAttribute, of: element) else { return nil }
        var topLeftOrigin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &topLeftOrigin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return PointingTargetGeometry.flipBetweenTopLeftAndAppKit(CGRect(origin: topLeftOrigin, size: size),
                                                                  primaryDisplayHeight: primaryDisplayHeight)
    }

    private static func axValueAttribute(_ attributeName: String, of element: AXUIElement) -> AXValue? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue, CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        return (attributeValue as! AXValue)
    }
}
