# AskClaude

Standalone watchOS SwiftUI app for chatting with Claude Code about the
Second Brain vault, via the Mac-side watch-bridge daemon
(`claude-cli-chat/scripts/watch-bridge/`) over Tailscale.

## Setup

1. Create `Sources/Secrets.swift` (gitignored) with the bridge bearer token
   from `~/.config/watch-bridge/token`:

   ```swift
   enum Secrets {
       static let bridgeToken = "<token>"
   }
   ```

2. Generate the Xcode project and build:

   ```sh
   xcodegen generate
   open AskClaude.xcodeproj
   ```

3. In Xcode: Signing & Capabilities → pick your team, select the watch as
   the run destination, ⌘R.

Host, port, and token are editable at runtime in the app's Settings screen;
`Secrets.bridgeToken` and the tailnet host in `BridgeConfig` are only the
first-launch defaults.

## Done notifications

Closing the app (wrist down) while Claude is still working arms a background
`URLSession` long-poll against the bridge's `GET /wait` endpoint
(`TurnNotifier`). When the turn finishes, watchOS wakes the app in the
background, a local notification with the reply preview fires, and the full
reply is stashed; tapping the notification (or reopening the app) merges it
into the chat. Local notifications only; no APNs or paid push setup. Allow
notifications on first launch when prompted.
