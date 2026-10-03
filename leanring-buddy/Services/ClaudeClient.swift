//
//  ClaudeClient.swift
//  Sage
//
//  Streams Claude's reply from the Sage Worker over Server-Sent Events.
//
//  The Worker decides the model, token limits, and system prompt. The app
//  only sends which mode it wants plus the conversation: past exchanges as
//  plain text, then the new question with a screenshot of each display.
//

import Foundation

/// Which system prompt the Worker should use.
enum ConversationMode: String {
    /// Normal push-to-talk conversation.
    case companion
    /// The first-run demo, where Sage points at something on screen to show off.
    case onboarding
}

/// One earlier exchange, replayed as text so Claude remembers the conversation.
struct ConversationTurn {
    let userText: String
    let assistantText: String
}

enum ClaudeStreamEvent {
    /// More reply text arrived.
    case textDelta(String)
    /// Claude declined to answer (a safety classifier refusal).
    case refusal
}

struct ClaudeClientError: LocalizedError {
    /// HTTP status from the Worker, or nil when the failure came mid-stream.
    let httpStatusCode: Int?
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class ClaudeClient {
    private let urlSession: URLSession

    init() {
        let sessionConfiguration = URLSessionConfiguration.default
        // Give up after 30 seconds of silence from the server, so a dead
        // connection turns into a clear "try again" instead of an endless spinner.
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 120
        // Don't keep screenshots or replies in any on-disk cache.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    /// Opens a connection to the Worker in the background so the first real
    /// request (which carries big screenshots) skips the TLS handshake.
    func warmUpConnection() {
        guard let workerBaseURL = AppConfiguration.workerBaseURL else { return }
        var warmUpRequest = URLRequest(url: workerBaseURL.appendingPathComponent("health"))
        warmUpRequest.timeoutInterval = 10
        urlSession.dataTask(with: warmUpRequest) { _, _, _ in
            // The response doesn't matter. The open connection is the point.
        }.resume()
    }

    /// Sends the question and calls `onEvent` for each piece of the reply as it streams in.
    /// Returns when the stream ends. Throws on network, HTTP, or stream errors.
    func streamReply(
        mode: ConversationMode,
        conversationHistory: [ConversationTurn],
        capturedScreens: [CapturedScreen],
        userText: String,
        onEvent: (ClaudeStreamEvent) -> Void
    ) async throws {
        var chatRequest = try AppConfiguration.makeWorkerRequest(path: "chat")
        chatRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": mode.rawValue,
            "messages": buildMessages(
                conversationHistory: conversationHistory,
                capturedScreens: capturedScreens,
                userText: userText
            )
        ])

        let payloadSizeInMegabytes = Double(chatRequest.httpBody?.count ?? 0) / 1_048_576
        print("🌐 Claude request (\(mode.rawValue)): \(String(format: "%.1f", payloadSizeInMegabytes))MB, \(capturedScreens.count) screenshot(s)")

        let (responseByteStream, response) = try await urlSession.bytes(for: chatRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeClientError(httpStatusCode: nil, message: "The Worker sent back something that isn't HTTP.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await errorBodyLine in responseByteStream.lines {
                errorBodyLines.append(errorBodyLine)
            }
            throw ClaudeClientError(
                httpStatusCode: httpResponse.statusCode,
                message: "Worker error \(httpResponse.statusCode): \(errorBodyLines.joined(separator: " "))"
            )
        }

        // Each SSE event we care about is a line like: data: {"type": "...", ...}
        for try await streamLine in responseByteStream.lines {
            try Task.checkCancellation()

            guard streamLine.hasPrefix("data: ") else { continue }
            let eventJSONText = String(streamLine.dropFirst("data: ".count))

            guard let eventJSONData = eventJSONText.data(using: .utf8),
                  let streamEvent = try? JSONSerialization.jsonObject(with: eventJSONData) as? [String: Any],
                  let streamEventType = streamEvent["type"] as? String else {
                continue
            }

            switch streamEventType {
            case "content_block_delta":
                // Thinking blocks also stream deltas; only text deltas are spoken.
                if let delta = streamEvent["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let textChunk = delta["text"] as? String {
                    onEvent(.textDelta(textChunk))
                }
            case "message_delta":
                if let delta = streamEvent["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    onEvent(.refusal)
                }
            case "error":
                let errorDetails = streamEvent["error"] as? [String: Any]
                let errorMessage = errorDetails?["message"] as? String ?? "unknown stream error"
                throw ClaudeClientError(httpStatusCode: nil, message: "Claude stream error: \(errorMessage)")
            case "message_stop":
                return
            default:
                continue
            }
        }
    }

    /// Builds the Messages API conversation: past turns as plain text (no old
    /// screenshots, to keep requests small), then the new question with a
    /// labeled screenshot of each display.
    private func buildMessages(
        conversationHistory: [ConversationTurn],
        capturedScreens: [CapturedScreen],
        userText: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        for pastTurn in conversationHistory {
            messages.append(["role": "user", "content": pastTurn.userText])
            messages.append(["role": "assistant", "content": pastTurn.assistantText])
        }

        var newQuestionContentBlocks: [[String: Any]] = []
        for capturedScreen in capturedScreens {
            newQuestionContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": capturedScreen.jpegData.base64EncodedString()
                ]
            ])
            newQuestionContentBlocks.append([
                "type": "text",
                "text": capturedScreen.labelForClaude
            ])
        }
        newQuestionContentBlocks.append([
            "type": "text",
            "text": userText
        ])
        messages.append(["role": "user", "content": newQuestionContentBlocks])

        return messages
    }
}
