import AppKit
import SwiftUI
import Combine

/// Captures SwiftUI's `openWindow` action so AppKit surfaces (the menu-bar
/// popover, which lives outside the scene graph and has no working `openWindow`
/// environment) can reopen the main window after it has been closed. The main
/// window records the action on appear; the closure stays valid for the app's
/// lifetime even once the window is gone.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
    weak var mainWindow: NSWindow?

    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            open?("main")
        }
    }
    private init() {}
}

/// macOS keeps one real status button and draws a copy of it in every other menu bar, and it moves that button between
/// displays as the active one changes, taking an attached popover along. A click on a copy still reaches the button, so
/// the popover anchors here instead, on the display that was clicked.
@MainActor
final class PopoverAnchor {
    private lazy var window: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        return panel
    }()

    func view(for button: NSView, click: NSPoint = NSEvent.mouseLocation) -> NSView {
        // NSMouseInRect because a menu-bar click sits on the screen's top edge, which NSRect.contains leaves out.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(click, $0.frame, false) }),
              let anchor = window.contentView else { return button }
        window.setFrameTopLeftPoint(NSPoint(x: click.x, y: screen.visibleFrame.maxY))
        window.orderFront(nil)
        return anchor
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// AppKit-backed menu-bar system monitor. A SwiftUI `MenuBarExtra` was avoided
/// here: a conditional `.window`-style `MenuBarExtra` fails to type-check, and
/// an unconditional one stalls the XCTest host's run loop. An `NSStatusItem`
/// driving an `NSPopover` (which hosts the existing SwiftUI `MenuBarMonitorView`)
/// gives the same UI with full create/destroy control and no test-host impact.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let anchor = PopoverAnchor()
    private let monitor = SystemMonitor.shared
    private let monitorOwner = UUID()
    private var cancellable: AnyCancellable?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Persist the user's show/hide choice and ensure the item is requested
        // visible (it defaults hidden when restored from a prior autosave state).
        statusItem.autosaveName = "PureMacSystemMonitor"
        statusItem.isVisible = true

        monitor.start(owner: monitorOwner)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: String(localized: "System Monitor")
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            updateTitle()
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 248, height: 230)
        let content = NSHostingController(rootView: MenuBarMonitorView())
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.delegate = self

        // Refresh the menu-bar CPU readout each time the monitor samples.
        cancellable = monitor.$cpuUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
    }

    /// Remove the status item and release the monitor observer. Called by
    /// AppDelegate before dropping the controller so teardown runs on the main
    /// actor (a `@MainActor` deinit cannot touch isolated state safely).
    func teardown() {
        cancellable?.cancel()
        cancellable = nil
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(statusItem)
        monitor.stop(owner: monitorOwner)
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.title = " \(Int((monitor.cpuUsage * 100).rounded()))%"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let view = anchor.view(for: button)
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        anchor.hide()
    }
}
