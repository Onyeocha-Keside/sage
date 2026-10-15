//
//  CursorIndicatorViews.swift
//  Sage
//
//  The small pieces Sage's cursor is made of: the triangle, the listening
//  waveform, the thinking spinner, and the speech bubble.
//

import Foundation
import SwiftUI

/// Sage's cursor shape: an equilateral triangle, rotated to look like a pointer.
struct CursorTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var trianglePath = Path()
        let sideLength = min(rect.width, rect.height)
        let triangleHeight = sideLength * sqrt(3.0) / 2.0

        trianglePath.move(to: CGPoint(x: rect.midX, y: rect.midY - triangleHeight / 1.5))
        trianglePath.addLine(to: CGPoint(x: rect.midX - sideLength / 2, y: rect.midY + triangleHeight / 3))
        trianglePath.addLine(to: CGPoint(x: rect.midX + sideLength / 2, y: rect.midY + triangleHeight / 3))
        trianglePath.closeSubpath()
        return trianglePath
    }
}

/// Five bars that bounce with your voice while you hold the shortcut.
struct ListeningWaveformView: View {
    let audioPowerLevel: CGFloat
    @Environment(\.sageCursorColor) private var cursorColor

    private let barHeightProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(barHeightProfile.indices, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(cursorColor)
                        .frame(width: 2, height: barHeight(barIndex: barIndex, timelineDate: timelineContext.date))
                }
            }
            .shadow(color: cursorColor.opacity(0.6), radius: 6)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(barIndex: Int, timelineDate: Date) -> CGFloat {
        let idleAnimationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let noiseFloorAdjustedLevel = max(audioPowerLevel - 0.008, 0)
        let easedLevel = pow(min(noiseFloorAdjustedLevel * 2.85, 1), 0.76)
        let voiceReactiveHeight = easedLevel * 10 * barHeightProfile[barIndex]
        let idlePulseHeight = (sin(idleAnimationPhase) + 1) / 2 * 1.5
        return 3 + voiceReactiveHeight + idlePulseHeight
    }
}

/// A spinning arc shown while Sage is transcribing, looking, and thinking.
struct ThinkingSpinnerView: View {
    @State private var isSpinning = false
    @Environment(\.sageCursorColor) private var cursorColor

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(colors: [cursorColor.opacity(0), cursorColor], center: .center),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: cursorColor.opacity(0.6), radius: 6)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

/// The little rounded label that appears next to the cursor.
struct CursorSpeechBubble: View {
    let text: String
    /// Extra glow while the bubble is popping in (0 = settled).
    var extraGlowAmount: CGFloat = 0
    @Environment(\.sageCursorColor) private var cursorColor
    @Environment(\.sageCursorTextColor) private var textColor

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cursorColor)
                    .shadow(
                        color: cursorColor.opacity(0.5 + extraGlowAmount),
                        radius: 6 + extraGlowAmount * 16
                    )
            )
            .fixedSize()
    }
}

/// A soft ring that keeps expanding and fading around the cursor while Sage
/// is in follow-along mode, as a quiet "go ahead, I'm watching" signal.
struct FollowAlongPulseView: View {
    @State private var isExpanded = false
    @Environment(\.sageCursorColor) private var cursorColor

    var body: some View {
        Circle()
            .stroke(cursorColor, lineWidth: 1.5)
            .frame(width: 30, height: 30)
            .scaleEffect(isExpanded ? 1.6 : 0.6)
            .opacity(isExpanded ? 0 : 0.8)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}

/// A clean ring around what the user circled. It strokes itself in, like a
/// pen finishing the circle, then stays until Sage has answered.
struct CircledAreaRing: View {
    /// In this overlay's view coordinates.
    let ringRect: CGRect
    @Environment(\.sageCursorColor) private var cursorColor
    @State private var drawProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Ellipse()
                .fill(cursorColor.opacity(0.08 * drawProgress))
            Ellipse()
                .trim(from: 0, to: drawProgress)
                .stroke(cursorColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: cursorColor.opacity(0.7), radius: 6)
        }
        .frame(width: ringRect.width, height: ringRect.height)
        .position(x: ringRect.midX, y: ringRect.midY)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                drawProgress = 1
            }
        }
    }
}
