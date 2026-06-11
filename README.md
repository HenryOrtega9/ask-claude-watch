# AskClaude

Standalone watchOS SwiftUI app for chatting with Claude Code from an Apple
Watch. A thin client over a Mac-side bridge daemon
([claude-cli-chat](https://github.com/HenryOrtega9/claude-cli-chat)
`scripts/watch-bridge/`) that holds one interactive `claude` session and
exposes it over a bearer-authed HTTP API across a Tailscale tailnet.

Features: dictated or typed chat with full conversation context, a model and
effort picker (driven by `/model` and `/effort` slash commands typed into the
session), a Sessions tab that can view and message any live Claude session on
the Mac, plan-limit usage gauges, Activity-style dual-ring watch-face
complications, and background done-notifications when a turn finishes after
the wrist drops.

## Setup

1. Create `Sources/Secrets.swift` (gitignored) with the bridge bearer token
   from `~/.config/watch-bridge/token`:

   ```swift
   enum Secrets {
       static let bridgeToken = "<token>"
   }
   ```

2. Open the Xcode project and build:

   ```sh
   open AskClaude.xcodeproj
   ```

   Do not run `xcodegen generate`: `project.yml` predates the widget target
   and the app-group entitlements, so regenerating would drop both. The
   checked-in `.xcodeproj` is the source of truth.

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
