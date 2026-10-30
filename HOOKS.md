# HOOKS.md — client/ hooks inside the engine

Project rule: `client/` does NOT edit the engine except for **minimal,
backward-compatible hooks documented here**. On every upstream update
(`engine/update.sh`), this list is the only thing to review if there are conflicts
on the Flutter side.

| # | File (engine/rustdesk/) | What | Why |
|---|---|---|---|
| 1 | `flutter/lib/desktop/pages/remote_page.dart` | Optional `showToolbar = true` param on `RemotePage`; with `false` it doesn't mount the built-in `RemoteToolbar` | `client/` suppresses RustDesk's toolbar and overlays its own (`client/lib/session/session_toolbar.dart`). Default `true` ⇒ the engine's own app doesn't change at all |
| 2 | `flutter/lib/models/peer_model.dart` | `Peer.machineId` and `Peer.onlineKnown` from the event JSON (`machine_id`, `online`); `Peers._updatePeers` keeps the engine's `online` verdict for peers that carry one instead of copying the previous list's state | `client/lib/home.dart` groups a host's addresses by its engine id and hides the old leases of a machine the engine's scan did not find. Lists without those keys (recent, favorites) behave exactly as upstream |
| 3 | `src/keyboard.rs`, `src/server/input_service.rs` | Forward Caps Lock transitions from a grabbed macOS client to a macOS host in every keyboard mode; host injects each transition once and updates its lock-state cache | Upstream drops the actual key and only synchronizes uppercase state on later keys, losing input-source switches. Uses existing Map packets; rebuild both client and host engines for the complete fix |
| 4 | `libs/hbb_common/protos/message.proto`, `src/flutter.rs`, `src/ui_session_interface.rs`, `src/server/{connection,input_service}.rs`, `src/platform/macos{.rs,.mm,_gestures.mm}`, `build.rs` | Optional structured Dock gesture pointer packets, host capability advertisement and main-thread native replay with cancellation watchdog | macOS 14–26 client captures system gestures for Spaces/full-screen apps, Mission Control and App Exposé. Existing pointer permissions apply; older peers ignore the new field and the client only captures for hosts advertising support. Native fields are private and require two-Mac acceptance testing; see `docs/tests/macos-gestures.md` |

Notes:
- Hooks are marked in the code with a `remotedisplay:` comment.
- Everything else `client/` needs from the engine is consumed as a package
  (`flutter_hbb` by path) without modifying it: `RemotePage`, models, toolbar
  helpers (`toolbarImageQuality`/`toolbarCodec`), `handleUriLink`, etc.
