# Mac client → Mac host: Caps Lock input-source switching

The grab loop used to pass Caps Lock through locally without forwarding it.
Legacy conversion also explicitly dropped lock keys. Lock-state synchronization
on a later letter cannot represent a language-switch tap with the uppercase lock off.

The client now forwards macOS Caps Lock transitions as existing Map packets in
all three keyboard modes. It preserves local handling and excludes these lock
transitions from focus-loss key releases. The host injects the explicit transition
once, bypasses automatic LED synchronization for that packet, and caches the
packet's uppercase state separately from its press/release direction.

## Automated checks

On a machine with the engine's native dependencies installed:

```sh
cd engine/rustdesk
cargo test --lib caps_lock_tests
```

These regression tests cover both event directions in Map, Legacy and Translate,
Caps Lock off during a language switch, uppercase state independent of direction,
and isolation from other keys and peer platforms. They do not verify macOS input
source behavior or permissions.

## Two-machine acceptance check (still required)

Rebuild the Rust engine for **both** the macOS client and macOS server. Updating
only Flutter or only the Swift menu-bar app does not include this change.

1. On the host, enable English and Thai input sources and “Use the Caps Lock key
   to switch to and from …” under System Settings → Keyboard → Text Input → Edit.
   Confirm a local Caps Lock tap switches the host input source.
2. Connect from another Mac, focus a text field on the remote desktop, and use
   Map mode. Tap Caps Lock repeatedly, typing after each tap. Confirm each tap
   switches the host input source immediately, including taps with no text after
   them, and that typing uses the selected host language.
3. Repeat in Legacy and Translate modes. These modes can send client-translated
   text; check the host's input-source indicator separately from typed text.
4. Hold Caps Lock for uppercase, then return to language switching. Check for
   duplicate toggles, unexpected lowercase/uppercase, or a stuck lock.
5. Click outside the session, press Caps Lock, and return. Confirm an unfocused
   session does not receive that key and focusing/unfocusing does not inject an
   extra Caps Lock transition. Repeat with a second session window.
6. Check normal letters, Shift, Command shortcuts and Num Lock; confirm existing
   Windows/Linux peer lock behavior is unchanged.

Local validation: all three conversion tests passed in an isolated `rustc --test`
harness using the production conversion functions with stand-ins for dependency
types and traps for unexpected fallback/live-keyboard calls. This checks conversion
logic, not compatibility with the real dependency types or host event injection.
Both modified Rust files parse with `rustfmt`, and `git diff --check` passes.
The local offline Cargo check was blocked by a missing `hwcodec` Git dependency.
Full client/server engine and application release builds subsequently succeeded
in [GitHub Actions](https://github.com/noxhsxrk/remotedisplay/actions/runs/41055054548),
with tests skipped at the user's request.
End-to-end language switching has not been verified on two Macs.
