#!/bin/bash
# Type-check and run logic checks without building or signing an app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d "${TMPDIR:-/tmp}/sage-check.XXXXXX")
trap 'rm -rf "$check_directory"' EXIT
swift_sources=()
while IFS= read -r source_path; do swift_sources+=("$source_path"); done < <(find leanring-buddy -name '*.swift' | sort)
swiftc -typecheck -swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility -module-name Sage -module-cache-path "$check_directory/cache" "${swift_sources[@]}"
swiftc -emit-module -enable-testing -swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility -module-name Sage -module-cache-path "$check_directory/cache" "${swift_sources[@]}" -emit-module-path "$check_directory/Sage.swiftmodule"
developer_directory=$(xcode-select -p)
swiftc -typecheck -swift-version 5 -enable-upcoming-feature MemberImportVisibility -F "$developer_directory/Platforms/MacOSX.platform/Developer/Library/Frameworks" -plugin-path "$developer_directory/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" -I "$check_directory" -module-cache-path "$check_directory/cache" $(find leanring-buddyTests -name '*.swift' | sort)
swiftc -swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility -module-cache-path "$check_directory/cache" \
  leanring-buddy/App/AppConfiguration.swift \
  leanring-buddy/App/AccessTokenStore.swift \
  leanring-buddy/Services/Input/PushToTalkShortcut.swift \
  leanring-buddy/Services/Networking/ChatProtocol.swift \
  leanring-buddy/Session/Conversation/ConversationMemory.swift \
  leanring-buddy/Session/FollowAlong/FollowAlongSession.swift \
  leanring-buddy/Services/Networking/ClaudeStreamDecoder.swift \
  leanring-buddy/Services/Networking/SageAPIClient.swift \
  leanring-buddy/Session/Reply/ReplyAssembly.swift \
  leanring-buddy/Session/Reply/ReplyExecutor.swift \
  leanring-buddy/Services/ScreenCapture/ScreenCaptureService.swift \
  leanring-buddy/Session/Reply/PointingTag.swift \
  leanring-buddy/Session/Pointing/PointingTargetGeometry.swift \
  leanring-buddy/Services/ScreenCapture/ScreenSettleTracker.swift \
  leanring-buddy/Services/Input/CircleGestureDetector.swift \
  leanring-buddy/Session/Reply/StreamingResponseSegmenter.swift \
  leanring-buddy/Services/Speech/SpeechVoice.swift \
  leanring-buddy/Services/Speech/SpeechPlaybackQueue.swift \
  scripts/SwiftRegressionChecks.swift -o "$check_directory/checks"
"$check_directory/checks"
