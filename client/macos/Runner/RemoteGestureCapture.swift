import Cocoa

// remotedisplay: intercept Dock gestures before they switch the local Spaces.
// The private Dock event layout is restricted to macOS 14–26; see the test notes.
// All state and callbacks belong to the main run loop.
final class RemoteGestureCapture {
    static let shared = RemoteGestureCapture()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private weak var window: NSWindow?
    private var send: (([String: Any]) -> Void)?
    private var lease: TimeInterval = 0
    private var current: [String: Any]?
    private var suppressMarker = false
    private var drainingAxis: Int64?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self, let sender = note.object as? NSWindow,
                      sender === self.window else { return }
                self.deactivate()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in self?.deactivate() })
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.send != nil && !self.eligible { self.deactivate() }
        }
    }

    private var eligible: Bool {
        guard let window = window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.isVisible
            && Date.timeIntervalSinceReferenceDate - lease < 1.0
    }

    func configure(window: NSWindow, enabled: Bool, send: @escaping ([String: Any]) -> Void) -> String {
        precondition(Thread.isMainThread)
        if !enabled || !window.isKeyWindow || !NSApp.isActive {
            if self.window === window { deactivate() }
            return "inactive"
        }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard (14...26).contains(major) else { return "unsupported" }
        guard AXIsProcessTrusted() else { return "permission-denied" }
        guard installTap() else { return "unavailable" }
        if self.window !== window { deactivate() }
        self.window = window
        self.send = send
        lease = Date.timeIntervalSinceReferenceDate
        // Keep a stationary, still-held gesture alive on the host too.
        if var packet = current {
            packet["phase"] = 2
            packet["velocity"] = 0.0
            send(packet)
        }
        return "active"
    }

    private func deactivate() {
        if var packet = current {
            drainingAxis = packet["axis"] as? Int64
            packet["phase"] = 8
            packet["velocity"] = 0.0
            send?(packet)
        }
        current = nil
        send = nil
        window = nil
        lease = 0
    }

    private func installTap() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<RemoteGestureCapture>.fromOpaque(context).takeUnretainedValue()
            return capture.receive(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Do not recapture events injected by a server on this same machine.
        if event.getIntegerValueField(.eventSourceUserData) == 0x524447455354 {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            deactivate()
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Finish consuming a gesture that we cancelled on blur. Forwarding its
        // remaining frames locally would give Dock a sequence without a beginning.
        if type.rawValue == 29 && suppressMarker {
            suppressMarker = false
            return nil
        }
        if type.rawValue == 30 && integer(event, 110) == 23, let axis = drainingAxis {
            let phase = integer(event, 132)
            if phase == 1 {
                drainingAxis = nil
            } else if integer(event, 123) == axis {
                if phase == 4 || phase == 8 { drainingAxis = nil }
                suppressMarker = true
                return nil
            }
        }
        guard send != nil, eligible else {
            if send != nil { deactivate() }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 30, integer(event, 110) == 23 else { return Unmanaged.passUnretained(event) }
        let axis = integer(event, 123)
        let phase = integer(event, 132)
        let progress = number(event, 124)
        let velocity = number(event, 129)
        guard (1...3).contains(axis), [1, 2, 4, 8].contains(phase),
              progress.isFinite, abs(progress) <= 16, velocity.isFinite, abs(velocity) <= 10000 else {
            deactivate()
            return Unmanaged.passUnretained(event)
        }
        // Never take over a gesture that began outside the session.
        guard phase == 1 || current != nil else { return Unmanaged.passUnretained(event) }
        let packet: [String: Any] = ["axis": axis, "phase": phase, "progress": progress,
                                     "velocity": velocity, "inverted": integer(event, 136) != 0]
        send?(packet)
        current = (phase == 4 || phase == 8) ? nil : packet
        suppressMarker = true
        return nil
    }

    private func integer(_ event: CGEvent, _ field: UInt32) -> Int64 {
        return event.getIntegerValueField(CGEventField(rawValue: field)!)
    }
    private func number(_ event: CGEvent, _ field: UInt32) -> Double {
        return event.getDoubleValueField(CGEventField(rawValue: field)!)
    }
}
