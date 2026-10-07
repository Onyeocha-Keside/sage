import Foundation

enum ReplyFailureExplanation {
    // MARK: - Error Messages

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Turns an error into one short sentence Sage can say out loud.
    static func spokenExplanation(for error: Error) -> String {
        if error is SageConfigurationError {
            return "i'm not set up yet. check the worker address, then enter your access token in the sage menu."
        }
        if error is ScreenCaptureFailure {
            return "i couldn't see your screen. make sure screen recording is turned on for sage."
        }
        if let claudeClientError = error as? SageAPIError, let httpStatusCode = claudeClientError.httpStatusCode {
            switch httpStatusCode {
            case 401:
                return "your access token is invalid or has been revoked. enter a valid token in the sage menu."
            case 429:
                return "your usage allowance or request limit has been reached. check with whoever provided your sage access."
            case 500...599:
                return "my brain is having a moment on the server side. try again in a few seconds."
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "looks like you're offline. check your wifi, then ask me again."
            case .timedOut:
                return "my connection timed out. your internet might be slow right now, try asking again."
            default:
                return "i can't reach my server. check your internet, or make sure the worker is running."
            }
        }
        return "something went wrong on my end. try that again."
    }
}
