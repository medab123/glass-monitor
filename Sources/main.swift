import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

/// System-wide hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x474C_4D4E), id: 1),
                            GetApplicationEventTarget(), 0, &reference)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let prefs = Prefs.shared
    private let panel = FloatingPanel()
    private let notifier = Notifier()
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var modifierTimer: Timer?
    private var visibilityTimer: Timer?
    private var hiddenForFullScreen = false
    private var lastScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: RootView(m: monitor))
        host.sizingOptions = []
        panel.contentView = host
        place(animated: false)
        panel.orderFrontRegardless()

        // @Published fires before the value is stored, so re-place on the next runloop turn.
        let relayout = { [weak self] in DispatchQueue.main.async { self?.place(animated: true) } }
        monitor.$expanded.dropFirst().sink { [weak self] _ in relayout(); self?.updateMouseHandling() }.store(in: &cancellables)
        monitor.$alert.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in relayout() }.store(in: &cancellables)
        prefs.$pillItems.dropFirst().sink { _ in relayout() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(animated: false) }
            .store(in: &cancellables)

        prefs.$opacity.sink { [weak self] in self?.panel.alphaValue = $0 }.store(in: &cancellables)
        prefs.$hideFromSharing.sink { [weak self] in self?.panel.sharingType = $0 ? .none : .readOnly }.store(in: &cancellables)
        prefs.$clickThrough.sink { [weak self] in self?.setClickThrough($0) }.store(in: &cancellables)

        monitor.onDrag = { [weak self] in self?.drag() }
        monitor.onDragEnd = { [weak self] in self?.endDrag() }
        monitor.onSnapToCorner = { [weak self] in
            self?.anchor = nil
            self?.place(animated: true)
        }

        notifier.setup()
        monitor.onAlert = { [weak self] in self?.notifier.post($0) }
        notifier.onQuit = { [weak self] pid in
            self?.monitor.kill(pid: pid, name: "process", force: false, key: "alert")
            self?.monitor.dismissAlert()
        }
        notifier.onIgnore = { [weak self] name in self?.monitor.ignore(processName: name) }
        notifier.onOpen = { [weak self] in withAnimation(.snappy(duration: 0.25)) { self?.monitor.expanded = true } }

        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey) { [weak self] in
            guard let self else { return }
            if hiddenForFullScreen { panel.orderFrontRegardless() }
            withAnimation(.snappy(duration: 0.25)) { self.monitor.expanded.toggle() }
        }

        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateFullScreenVisibility()
        }

        monitor.start()
        if CommandLine.arguments.contains("--expanded") { monitor.expanded = true }
        if let tab = CommandLine.arguments.first(where: { $0.hasPrefix("--tab=") })
            .flatMap({ ListTab(rawValue: String($0.dropFirst(6))) }) { monitor.tab = tab }
        if CommandLine.arguments.contains("--test-alert") { monitor.showTestAlert() }
        LoginItem.migrate()
        if CommandLine.arguments.contains("--register-login") { LoginItem.setEnabled(true) }
        if CommandLine.arguments.contains("--unregister-login") { LoginItem.setEnabled(false) }
    }

    // MARK: Click-through

    private func setClickThrough(_ on: Bool) {
        modifierTimer?.invalidate()
        modifierTimer = nil
        if on {
            // Polling the modifier state needs no Accessibility permission, unlike a global event monitor.
            modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateMouseHandling()
            }
        }
        DispatchQueue.main.async { self.updateMouseHandling() }
    }

    private func updateMouseHandling() {
        let interactive = !prefs.clickThrough || monitor.expanded || NSEvent.modifierFlags.contains(.option)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    // MARK: Full-screen hiding

    private func updateFullScreenVisibility() {
        let hide = prefs.hideInFullScreen && !monitor.expanded && frontAppIsFullScreen()
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        hide ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    /// True when the frontmost app has a window exactly covering the panel's screen (native or video full screen).
    private func frontAppIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let screen = lastScreen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return false }
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - target.minX) < 1 && abs(rect.minY - target.minY) < 1
                && abs(rect.width - target.width) < 1 && abs(rect.height - target.height) < 1
        }
    }

    // MARK: Placement

    /// Top-right corner of the panel in global screen coordinates; nil means "default corner".
    /// Anchoring on the top-right keeps the pill in place when it expands or collapses.
    private var anchor: NSPoint? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "anchorX") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
        }
        set {
            let d = UserDefaults.standard
            if let p = newValue {
                d.set(p.x, forKey: "anchorX")
                d.set(p.y, forKey: "anchorY")
            } else {
                d.removeObject(forKey: "anchorX")
                d.removeObject(forKey: "anchorY")
            }
        }
    }

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func endDrag() {
        dragStart = nil
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        place(animated: true)
    }

    private func place(animated: Bool) {
        let size = RootView.size(expanded: monitor.expanded, alert: monitor.alert != nil, items: prefs.pillItems)
        let margin: CGFloat = 10

        let screen: NSScreen?
        var topRight: NSPoint
        if let anchor {
            screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) } ?? NSScreen.main
            topRight = anchor
        } else {
            screen = NSScreen.screens.first { $0.localizedName == monitor.screenName } ?? NSScreen.main
            let area = screen?.visibleFrame ?? .zero
            topRight = NSPoint(x: area.maxX - margin, y: area.maxY - margin)
        }
        guard let screen else { return }
        lastScreen = screen
        let area = screen.visibleFrame

        // Keep the whole panel on screen, e.g. when expanding near an edge.
        topRight.x = min(max(topRight.x, area.minX + size.width), area.maxX)
        topRight.y = min(max(topRight.y, area.minY + size.height), area.maxY)
        let frame = NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
        guard animated else { return panel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1) // springy ease-out
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }
}

guard LoginItem.claimSingleInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
