//
//  SageCursorView.swift
//  Sage
//
//  Sage's glowing cursor. One of these runs per screen, inside that screen's
//  overlay window. It:
//    - follows your mouse with a little spring
//    - becomes a waveform while you talk and a spinner while Sage thinks
//    - flies along an arc to whatever Sage is talking about, shows a label,
//      hops between elements during a walkthrough, then flies back home
//

import AppKit
import Foundation
import SwiftUI

private enum CursorNavigationMode {
    /// Following the mouse.
    case followingCursor
    /// Mid-flight, either toward a target or back to the mouse.
    case flying
    /// Parked next to a target, showing its label.
    case pointingAtTarget
}

struct SageCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var sessionCoordinator: SageSessionCoordinator

    /// Sage sits just below and to the right of the real mouse pointer.
    private static let offsetFromMouse = CGPoint(x: 35, y: 25)
    private static let restingRotationDegrees: Double = -35
    private static let welcomeMessage = "hey, i'm sage"
    private static let followSpring = Animation.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)

    @State private var cursorPosition: CGPoint
    @State private var isMouseOnThisScreen: Bool
    @State private var cursorOpacity: Double = 0
    @State private var mouseTrackingTimer: Timer?

    // Welcome bubble (first launch / replayed intro only).
    @State private var welcomeText = ""
    @State private var welcomeBubbleOpacity: Double = 0

    // Pointing and flight.
    @State private var navigationMode: CursorNavigationMode = .followingCursor
    /// The target this screen is currently flying to or pointing at.
    @State private var activeTargetID: UUID?
    @State private var triangleRotationDegrees: Double = SageCursorView.restingRotationDegrees
    @State private var flightScale: CGFloat = 1
    @State private var flightAnimationTimer: Timer?
    @State private var isFlyingHome = false
    @State private var mousePositionWhenFlightHomeStarted: CGPoint = .zero
    @State private var pointingBubbleText = ""
    @State private var pointingBubbleOpacity: Double = 0
    @State private var pointingBubbleScale: CGFloat = 1
    /// Bumped whenever the bubble's text is replaced, so a type-out still in
    /// progress for the old text stops instead of appending to the new one.
    @State private var pointingBubbleTextGeneration = 0

    init(screenFrame: CGRect, isFirstAppearance: Bool, sessionCoordinator: SageSessionCoordinator) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.sessionCoordinator = sessionCoordinator

        // Start at the mouse so the cursor doesn't flash at (0, 0) first.
        let mouseLocation = NSEvent.mouseLocation
        let mouseInView = CGPoint(
            x: mouseLocation.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - mouseLocation.y
        )
        _cursorPosition = State(initialValue: CGPoint(
            x: mouseInView.x + Self.offsetFromMouse.x,
            y: mouseInView.y + Self.offsetFromMouse.y
        ))
        _isMouseOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }

    var body: some View {
        ZStack {
            // Nearly invisible fill keeps the hosting view compositing correctly.
            Color.black.opacity(0.001)

            // The pen trail while the shortcut is held, then the finished loop
            // around what the user circled until Sage has answered.
            gestureTrail
            circledAreaHighlight
                .animation(.easeOut(duration: 0.2), value: sessionCoordinator.circledAreaFocusRect)

            speechBubbleNextToCursor(text: welcomeText)
                .opacity(isMouseOnThisScreen ? welcomeBubbleOpacity : 0)
                .animation(.easeOut(duration: 0.4), value: welcomeBubbleOpacity)

            speechBubbleNextToCursor(text: sessionCoordinator.onboardingPromptText)
                .opacity(isMouseOnThisScreen && navigationMode == .followingCursor ? sessionCoordinator.onboardingPromptOpacity : 0)
                .animation(.easeOut(duration: 0.3), value: sessionCoordinator.onboardingPromptOpacity)

            speechBubbleNextToCursor(text: pointingBubbleText, popInScale: pointingBubbleScale)
                .opacity(navigationMode == .pointingAtTarget ? pointingBubbleOpacity : 0)
                .animation(.easeOut(duration: 0.4), value: pointingBubbleOpacity)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pointingBubbleScale)

            if sessionCoordinator.isFollowingAlong && isCursorVisibleOnThisScreen {
                FollowAlongPulseView()
                    .position(cursorPosition)
                    .animation(navigationMode == .flying ? nil : Self.followSpring, value: cursorPosition)
                    .allowsHitTesting(false)
            }

            // The triangle, waveform, and spinner all stay in the view tree and
            // cross-fade, so SwiftUI never removes and re-inserts them (which
            // makes the cursor visibly pop).
            CursorTriangle()
                .fill(cursorColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: cursorColor, radius: 8 + (flightScale - 1) * 20)
                .scaleEffect(flightScale)
                .opacity(isCursorVisibleOnThisScreen && isShowingTriangle ? cursorOpacity : 0)
                .position(cursorPosition)
                // While flying, a timer moves the cursor every frame, so no implicit
                // animation. Parked at a target, the spring smooths scroll-following.
                .animation(navigationMode == .flying ? nil : Self.followSpring, value: cursorPosition)
                .animation(.easeIn(duration: 0.25), value: sessionCoordinator.voiceState)
                .animation(navigationMode == .flying ? nil : .easeInOut(duration: 0.3), value: triangleRotationDegrees)

            ListeningWaveformView(audioPowerLevel: sessionCoordinator.currentAudioPowerLevel)
                .opacity(isCursorVisibleOnThisScreen && sessionCoordinator.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(Self.followSpring, value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: sessionCoordinator.voiceState)

            ThinkingSpinnerView()
                .opacity(isCursorVisibleOnThisScreen && sessionCoordinator.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(Self.followSpring, value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: sessionCoordinator.voiceState)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        // Every indicator reads the chosen color from the environment.
        .environment(\.sageCursorColor, cursorColor)
        .environment(\.sageCursorTextColor, sessionCoordinator.cursorColorOption.textColor)
        // Voice-only mode: Sage still listens and talks, but draws nothing.
        .opacity(sessionCoordinator.cursorColorOption.isInvisible ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: sessionCoordinator.cursorColorOption)
        .ignoresSafeArea()
        .onAppear(perform: handleAppear)
        .onDisappear {
            mouseTrackingTimer?.invalidate()
            flightAnimationTimer?.invalidate()
        }
        .onChange(of: sessionCoordinator.currentPointingTarget) { _, newPointingTarget in
            handleNewPointingTarget(newPointingTarget)
        }
    }

    // MARK: - Drawing

    private var cursorColor: Color {
        sessionCoordinator.cursorColorOption.cursorColor
    }

    private var gestureTrail: some View {
        Path { trailPath in
            trailPath.addLines(sessionCoordinator.gestureTrailPoints.map(convertScreenPointToViewCoordinates))
        }
        .stroke(cursorColor.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .shadow(color: cursorColor.opacity(0.6), radius: 4)
        .allowsHitTesting(false)
    }

    /// Once the shortcut is released, the rough hand-drawn loop is replaced
    /// by a clean circle (or ellipse) that draws itself around the item.
    @ViewBuilder
    private var circledAreaHighlight: some View {
        if let focusRect = sessionCoordinator.circledAreaFocusRect {
            let ringRectInView = CGRect(
                x: focusRect.minX - screenFrame.minX,
                y: screenFrame.maxY - focusRect.maxY,
                width: focusRect.width,
                height: focusRect.height
            )
            CircledAreaRing(ringRect: ringRectInView)
                // A new circle replays the draw-in animation.
                .id("\(focusRect.origin.x),\(focusRect.origin.y),\(focusRect.width),\(focusRect.height)")
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Visibility

    /// The triangle shows when idle or speaking. While listening or thinking,
    /// the waveform or spinner takes its place.
    private var isShowingTriangle: Bool {
        sessionCoordinator.voiceState == .idle || sessionCoordinator.voiceState == .responding
    }

    /// Only one screen shows the cursor at a time: the one with the mouse,
    /// or the one currently flying to or pointing at a target.
    private var isCursorVisibleOnThisScreen: Bool {
        switch navigationMode {
        case .followingCursor:
            // Another screen is handling a target, so stay hidden to avoid two cursors.
            if sessionCoordinator.currentPointingTarget != nil {
                return false
            }
            return isMouseOnThisScreen
        case .flying, .pointingAtTarget:
            return true
        }
    }

    /// Places a bubble so its left edge sits just right of the cursor.
    /// The 1x1 anchor plus a leading overlay avoids measuring the bubble's size.
    private func speechBubbleNextToCursor(text: String, popInScale: CGFloat = 1) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: .leading) {
                if !text.isEmpty {
                    CursorSpeechBubble(text: text, extraGlowAmount: 1 - popInScale)
                        .scaleEffect(popInScale, anchor: .leading)
                        .offset(x: 10, y: 18)
                }
            }
            .position(cursorPosition)
            .animation(navigationMode == .flying ? nil : Self.followSpring, value: cursorPosition)
    }

    // MARK: - Appearance

    private func handleAppear() {
        let mouseLocation = NSEvent.mouseLocation
        isMouseOnThisScreen = screenFrame.contains(mouseLocation)
        cursorPosition = cursorPositionForMouse(at: mouseLocation)
        startTrackingMouse()

        if isFirstAppearance && isMouseOnThisScreen {
            withAnimation(.easeIn(duration: 1.5)) {
                cursorOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                playWelcomeAnimation()
            }
        } else {
            cursorOpacity = 1
        }
    }

    /// Types out "hey, i'm sage", holds it, fades it, then tells the companion
    /// to run the onboarding demo.
    private func playWelcomeAnimation() {
        welcomeText = ""
        welcomeBubbleOpacity = 1

        typeOutText(Self.welcomeMessage, characterIndex: 0, appendCharacter: { welcomeText.append($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                welcomeBubbleOpacity = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    welcomeText = ""
                    sessionCoordinator.welcomeAnimationDidFinish()
                }
            }
        }
    }

    // MARK: - Mouse Tracking

    private func startTrackingMouse() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            isMouseOnThisScreen = screenFrame.contains(mouseLocation)

            switch navigationMode {
            case .followingCursor:
                cursorPosition = cursorPositionForMouse(at: mouseLocation)
            case .flying:
                // On the way home, moving the mouse a lot snaps Sage back to following.
                guard isFlyingHome else { return }
                let mouseInView = convertScreenPointToViewCoordinates(mouseLocation)
                let distanceMovedSinceFlightHomeStarted = hypot(
                    mouseInView.x - mousePositionWhenFlightHomeStarted.x,
                    mouseInView.y - mousePositionWhenFlightHomeStarted.y
                )
                if distanceMovedSinceFlightHomeStarted > 100 {
                    finishPointingAndFollowMouse()
                }
            case .pointingAtTarget:
                break
            }
        }
    }

    private func cursorPositionForMouse(at mouseLocation: CGPoint) -> CGPoint {
        let mouseInView = convertScreenPointToViewCoordinates(mouseLocation)
        return CGPoint(x: mouseInView.x + Self.offsetFromMouse.x, y: mouseInView.y + Self.offsetFromMouse.y)
    }

    /// AppKit screen point (bottom-left origin) → this overlay's SwiftUI coordinates (top-left origin).
    private func convertScreenPointToViewCoordinates(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        )
    }

    // MARK: - Pointing

    private func handleNewPointingTarget(_ newPointingTarget: PointingTarget?) {
        guard let newPointingTarget else {
            // Cleared (for example the user interrupted). If we were pointing,
            // the hold check below notices and flies home on its own.
            return
        }

        let targetDisplayCenter = CGPoint(x: newPointingTarget.displayFrame.midX, y: newPointingTarget.displayFrame.midY)
        let isTargetOnThisScreen = screenFrame.contains(targetDisplayCenter) || newPointingTarget.displayFrame == screenFrame

        if isTargetOnThisScreen {
            if newPointingTarget.id == activeTargetID && navigationMode == .pointingAtTarget {
                // The same target moved (the user scrolled): glide with it.
                followMovedTarget(newPointingTarget)
            } else {
                // A new target, or the one being flown to moved mid-flight:
                // fly from wherever the cursor is now.
                flyToTarget(newPointingTarget)
            }
        } else if navigationMode != .followingCursor {
            // The walkthrough moved to another monitor. Stop here quietly
            // without clearing the target the other screen is flying to.
            resetToFollowingMouse()
        }
    }

    /// Just below-right of the element, so the triangle's tip points at it.
    private func parkingSpot(for pointingTarget: PointingTarget) -> CGPoint {
        let targetInView = convertScreenPointToViewCoordinates(pointingTarget.globalScreenLocation)
        return CGPoint(
            x: max(20, min(targetInView.x + 8, screenFrame.width - 20)),
            y: max(20, min(targetInView.y + 12, screenFrame.height - 20))
        )
    }

    /// The label, or which way to scroll when the element is out of view.
    private func bubbleText(for pointingTarget: PointingTarget) -> String {
        let label = (pointingTarget.label?.isEmpty == false) ? pointingTarget.label! : "right here"
        guard let offScreenEdge = pointingTarget.offScreenEdge else { return label }
        return pointingTarget.label?.isEmpty == false
            ? "\(offScreenEdge.scrollInstruction) for \(label)"
            : offScreenEdge.scrollInstruction
    }

    /// Resting tilt at a visible target; aimed at the edge for a hidden one.
    private func parkedRotationDegrees(for pointingTarget: PointingTarget) -> Double {
        pointingTarget.offScreenEdge?.cursorRotationDegrees ?? Self.restingRotationDegrees
    }

    private func followMovedTarget(_ pointingTarget: PointingTarget) {
        cursorPosition = parkingSpot(for: pointingTarget)
        triangleRotationDegrees = parkedRotationDegrees(for: pointingTarget)
        let newBubbleText = bubbleText(for: pointingTarget)
        if newBubbleText != pointingBubbleText {
            pointingBubbleTextGeneration += 1
            pointingBubbleText = newBubbleText
            pointingBubbleScale = 1
        }
    }

    private func flyToTarget(_ pointingTarget: PointingTarget) {
        let parkingSpot = parkingSpot(for: pointingTarget)

        activeTargetID = pointingTarget.id
        navigationMode = .flying
        isFlyingHome = false
        pointingBubbleOpacity = 0
        pointingBubbleText = ""

        animateFlightAlongArc(to: parkingSpot) {
            guard activeTargetID == pointingTarget.id, navigationMode == .flying else { return }
            startPointing(at: pointingTarget)
        }
    }

    private func startPointing(at pointingTarget: PointingTarget) {
        navigationMode = .pointingAtTarget
        triangleRotationDegrees = parkedRotationDegrees(for: pointingTarget)

        pointingBubbleTextGeneration += 1
        let typingGeneration = pointingBubbleTextGeneration
        pointingBubbleText = ""
        pointingBubbleScale = 0.5
        pointingBubbleOpacity = 1

        typeOutText(bubbleText(for: pointingTarget), characterIndex: 0, appendCharacter: { character in
            guard activeTargetID == pointingTarget.id, pointingBubbleTextGeneration == typingGeneration else { return }
            if pointingBubbleText.isEmpty {
                // Pop the bubble in as the first letter appears.
                pointingBubbleScale = 1
            }
            pointingBubbleText.append(character)
        }) {
            holdPointingThenFlyHome(targetID: pointingTarget.id, delaySeconds: 1.5)
        }
    }

    /// Stays parked at the target while Sage is still talking about it. A new
    /// target (the next walkthrough step) takes over by itself; otherwise,
    /// once the reply ends, the cursor fades its label and flies home.
    private func holdPointingThenFlyHome(targetID: UUID, delaySeconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            guard navigationMode == .pointingAtTarget, activeTargetID == targetID else { return }

            let isStillTalkingAboutThisTarget = sessionCoordinator.isReplyInProgress
                && sessionCoordinator.currentPointingTarget?.id == targetID
            if isStillTalkingAboutThisTarget {
                holdPointingThenFlyHome(targetID: targetID, delaySeconds: 0.3)
                return
            }

            pointingBubbleOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard navigationMode == .pointingAtTarget, activeTargetID == targetID else { return }
                flyHomeToMouse()
            }
        }
    }

    private func flyHomeToMouse() {
        let mouseLocation = NSEvent.mouseLocation
        mousePositionWhenFlightHomeStarted = convertScreenPointToViewCoordinates(mouseLocation)
        navigationMode = .flying
        isFlyingHome = true

        animateFlightAlongArc(to: cursorPositionForMouse(at: mouseLocation)) {
            finishPointingAndFollowMouse()
        }
    }

    /// Back to following the mouse, and tells the companion this target is done.
    private func finishPointingAndFollowMouse() {
        let finishedTargetID = activeTargetID
        resetToFollowingMouse()
        if let finishedTargetID {
            sessionCoordinator.clearPointingTarget(ifStillTargetID: finishedTargetID)
        }
    }

    private func resetToFollowingMouse() {
        flightAnimationTimer?.invalidate()
        flightAnimationTimer = nil
        navigationMode = .followingCursor
        activeTargetID = nil
        isFlyingHome = false
        triangleRotationDegrees = Self.restingRotationDegrees
        flightScale = 1
        pointingBubbleText = ""
        pointingBubbleOpacity = 0
        pointingBubbleScale = 1
    }

    // MARK: - Flight Animation

    /// Flies the cursor along a curved arc (a quadratic bezier) to `destination`.
    /// The triangle turns to face where it's heading and swells slightly at the
    /// top of the arc for a swooping feel.
    private func animateFlightAlongArc(to destination: CGPoint, onArrival: @escaping () -> Void) {
        flightAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let flightDistance = hypot(destination.x - startPosition.x, destination.y - startPosition.y)

        // Short hops are quick, long flights take a little longer.
        let flightDurationSeconds = min(max(flightDistance / 800.0, 0.5), 1.2)
        let frameIntervalSeconds = 1.0 / 60.0
        let totalFrameCount = max(Int(flightDurationSeconds / frameIntervalSeconds), 1)
        var currentFrameNumber = 0

        // Lift the arc's midpoint upward so the path curves like a thrown ball.
        let arcHeight = min(flightDistance * 0.2, 80.0)
        let arcControlPoint = CGPoint(
            x: (startPosition.x + destination.x) / 2,
            y: (startPosition.y + destination.y) / 2 - arcHeight
        )

        flightAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameIntervalSeconds, repeats: true) { _ in
            currentFrameNumber += 1

            if currentFrameNumber > totalFrameCount {
                flightAnimationTimer?.invalidate()
                flightAnimationTimer = nil
                cursorPosition = destination
                flightScale = 1
                onArrival()
                return
            }

            let linearProgress = CGFloat(currentFrameNumber) / CGFloat(totalFrameCount)
            // Smoothstep: slow start, fast middle, gentle landing.
            let easedProgress: CGFloat = linearProgress * linearProgress * (3 - 2 * linearProgress)
            let remainingProgress: CGFloat = 1 - easedProgress

            // Quadratic bezier: B(t) = (1-t)²·start + 2(1-t)t·control + t²·end
            let startWeight: CGFloat = remainingProgress * remainingProgress
            let controlWeight: CGFloat = 2 * remainingProgress * easedProgress
            let endWeight: CGFloat = easedProgress * easedProgress
            let positionX: CGFloat = startWeight * startPosition.x + controlWeight * arcControlPoint.x + endWeight * destination.x
            let positionY: CGFloat = startWeight * startPosition.y + controlWeight * arcControlPoint.y + endWeight * destination.y
            cursorPosition = CGPoint(x: positionX, y: positionY)

            // Face the direction of travel: the curve's tangent, B'(t). The +90°
            // is because the triangle's tip points up at 0° rotation.
            let towardControlWeight: CGFloat = 2 * remainingProgress
            let towardEndWeight: CGFloat = 2 * easedProgress
            let tangentX: CGFloat = towardControlWeight * (arcControlPoint.x - startPosition.x)
                + towardEndWeight * (destination.x - arcControlPoint.x)
            let tangentY: CGFloat = towardControlWeight * (arcControlPoint.y - startPosition.y)
                + towardEndWeight * (destination.y - arcControlPoint.y)
            let headingRadians: CGFloat = atan2(tangentY, tangentX)
            triangleRotationDegrees = Double(headingRadians * 180 / .pi) + 90

            // Swell to 1.3x at the midpoint, back to 1x on landing.
            flightScale = 1 + sin(linearProgress * .pi) * 0.3
        }
    }

    // MARK: - Typing Effect

    /// Reveals text one character at a time with slightly random delays,
    /// which reads more like someone talking than a fixed-speed ticker.
    private func typeOutText(
        _ text: String,
        characterIndex: Int,
        appendCharacter: @escaping (Character) -> Void,
        onFinished: @escaping () -> Void
    ) {
        guard characterIndex < text.count else {
            onFinished()
            return
        }

        appendCharacter(text[text.index(text.startIndex, offsetBy: characterIndex)])

        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.03...0.06)) {
            typeOutText(text, characterIndex: characterIndex + 1, appendCharacter: appendCharacter, onFinished: onFinished)
        }
    }
}
