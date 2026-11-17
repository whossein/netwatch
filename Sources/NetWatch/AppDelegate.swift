import AppKit
import SwiftUI
import Combine

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// پنل ویجت با کلیک روی هر جای پس‌زمینه کشیده می‌شود (isMovableByWindowBackground با SwiftUI کار نمی‌کند).
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var grab: NSPoint?

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grab = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let window, let grab {
            let p = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        super.mouseUp(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var widgetPanel: WidgetPanel?
    private var cancellables = Set<AnyCancellable>()
    private var shownTitle: String?
    private var shownIconKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.action = #selector(togglePopover(_:))
            b.target = self
            b.imagePosition = .imageLeft
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        updateStatusItem()

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(store))

        store.$live
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        store.$widgetVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in visible ? self?.showWidget() : self?.widgetPanel?.orderOut(nil) }
            .store(in: &cancellables)

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    func popoverDidShow(_ notification: Notification) { store.popoverOpen = true }
    func popoverDidClose(_ notification: Notification) { store.popoverOpen = false }

    /// رسم دوباره‌ی آیتم نوار منو گران است (روی همه‌ی نمایشگرها کپی می‌شود)؛ فقط وقتی متن یا آیکن عوض شده.
    private func updateStatusItem() {
        guard let b = statusItem.button else { return }
        let l = store.live
        let iconKey = l.map { $0.path ?? "#gear" } ?? "#idle"
        let title = l.map { " ↓\(compactRate($0.rx)) ↑\(compactRate($0.tx))" } ?? ""

        if iconKey != shownIconKey {
            if let l {
                b.image = IconCache.shared.menuIcon(for: l.path)
            } else {
                let i = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "NetWatch")
                i?.isTemplate = true
                b.image = i
            }
            shownIconKey = iconKey
        }
        if title != shownTitle {
            b.title = title
            shownTitle = title
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showWidget() {
        if widgetPanel == nil {
            let p = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 245),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.contentView = DraggableHostingView(rootView: WidgetView().environmentObject(store))

            if let s = UserDefaults.standard.string(forKey: "widgetOrigin") {
                p.setFrameOrigin(NSPointFromString(s))
            } else if let screen = NSScreen.screens.first {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 260 - 24, y: f.maxY - 245 - 24))
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { n in
                guard let w = n.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "widgetOrigin")
            }
            widgetPanel = p
        }
        widgetPanel?.orderFrontRegardless()
    }
}
