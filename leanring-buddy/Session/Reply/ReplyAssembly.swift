import Foundation

/// Everything gathered about the reply currently being streamed.
struct ReplyAssembly {
    let capturedScreens: [CapturedScreen]
    var spokenText = ""
    /// A tag Claude wrote whose sentence hasn't arrived yet.
    var pointingTargetForNextSentence: PointingTarget?
    var wasRefused = false
    /// Claude ended with [FOLLOW]: it's waiting for the user to act.
    var wantsToFollowAlong = false
}
