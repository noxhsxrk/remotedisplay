# Native macOS Dock gesture forwarding

Status: implementation and local native checks only; two-Mac acceptance is still
required before treating this as a working gesture passthrough feature.

## Behavior and supported scope

The primary interaction is a trackpad swipe between **Spaces and full-screen
apps**, preserving begin/change/end/cancel and continuous progress rather than
replacing the gesture with Control+Arrow. The same Dock event family includes
vertical Mission Control/App Exposé and system pinch. Finger count follows the
client's macOS Trackpad settings (three or four fingers).

Capture applies only to a key, active session window with the pointer over the
remote view, pointer permission, and a host advertising `macos_gestures_v1`.
The session toolbar is outside the capture region. Window blur/close, permission
loss and an expired Flutter lease cancel the remote sequence. Remaining frames
of a cancelled local sequence are consumed to avoid giving local Dock a partial
gesture. A stationary gesture sends keepalive progress every 250 ms; the host
cancels a sequence after 1.5 seconds with no packets. A new begin cancels the
previous owner's transition; other connections cannot finish that transition.

The client requires Accessibility permission to suppress system gestures. Failure
to create the tap leaves gestures local and is logged as `[gestures]`. Older hosts
never enable capture. Both native capture and host replay are gated to **macOS
14–26**. macOS 27's changed IOHID representation is deliberately unsupported.

This does **not** implement general trackpad passthrough for app-specific pinch,
rotation, force touch, lookup, or two-finger navigation. Existing two-finger
scrolling remains on the engine's existing path. Network and capture latency
still affect the animation; this is not a guarantee of local-machine latency.

## Transport and native event construction

Native capture uses a session CGEvent tap for types 29 and 30, retaining only
Dock subtype 23. It sends `{axis, phase, progress, velocity, inverted}` through a
dedicated Flutter channel and the existing `sessionSendPointer` FFI function.
The protobuf adds `MacosGestureEvent` at PointerDeviceEvent oneof field 3;
existing fields 1 and 2 are unchanged. The normal authenticated pointer-input
permission checks remain in place on the server.

The server constructs fresh events from bounded fields, never deserializes an
arbitrary CGEvent supplied by the peer. It validates axis, phase, finite progress
and velocity, rejects orphan frames, and posts each frame with its companion
marker on the main thread. Injected events are tagged to avoid local feedback.

The private field meanings were checked against the primary implementations
[dockswipe](https://github.com/oomol-lab/dockswipe/blob/main/dockswipe.m) and
[iss](https://github.com/joshuarli/iss). Fields 110, 123, 124, 129, 132 and 136
describe subtype, axis, progress, exit velocity, phase and inversion; redundant
fields retain the companion encodings used by Dock. Apple does not guarantee
these private fields. Apple's [trackpad event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
explains why system gestures take priority over ordinary app gesture handling.

## Local checks

From the repo root (the native harness records events and never injects input):

```sh
xcrun clang++ -std=c++17 -fblocks -framework AppKit -framework CoreGraphics \
  docs/tests/macos_gestures_test.mm -o /private/tmp/remotedisplay-gesture-tests
/private/tmp/remotedisplay-gesture-tests
xcrun swiftc -typecheck -module-cache-path /private/tmp/remotedisplay-swift-cache \
  client/macos/Runner/RemoteGestureCapture.swift
plutil -lint client/macos/Runner.xcodeproj/project.pbxproj
git diff --check
```

The native harness checks actual CGEvent field construction, invalid/non-finite
packets, ownership, phase ordering, completion and watchdog cancellation. Swift
typechecking covers the real Cocoa capture implementation, without Flutter.
These native checks passed locally on macOS 26; CGEvent progress is stored with
Float32 precision, so the harness compares progress using a tolerance.
Full Rust/Flutter builds are not validated here: Rust's offline dependency cache
lacks `hwcodec`, and the Flutter SDK is not installed in the current shell.

## Two-Mac acceptance checklist

1. Build and sign both the macOS client and server engine. A Swift server shell
   rebuild alone or a Flutter-only client rebuild does not include the protocol.
2. Give the client Accessibility permission. Connect to an updated macOS 14–26
   host with control enabled. Create two Spaces and a full-screen app on the host.
3. Place the pointer over the remote image. Swipe left/right slowly; check that
   the **host** animation follows progress while the **client** stays on its
   current Space. Finish the swipe, then repeat in reverse.
4. Start a swipe, hold fingers still for over two seconds, then continue. It
   should stay alive. Reverse before completion to cancel without switching.
5. Try Mission Control/App Exposé. Check direction with natural scrolling on/off
   and three-/four-finger settings. System pinch is additional coverage, not a
   substitute for testing app-specific zoom.
6. Blur or close the window midway, interrupt the connection, and revoke pointer
   permission. Check for cancellation within the watchdog interval and no stuck
   transition. Reconnect and start another gesture.
7. Open two session windows. Switch focus and verify only the active window's
   peer receives gesture frames. Home, toolbar and other apps retain local gestures.
8. Test view-only mode, an old host, denied client Accessibility and unsupported
   macOS. Capture must stay off. Check normal keyboard input, two-finger scrolling,
   pointer movement and Caps Lock switching for regressions.
