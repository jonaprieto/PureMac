import SwiftUI
import AppKit

/// Zero-size helper that captures SwiftUI's `openWindow` action into
/// `WindowOpener.shared` when the main window appears, so the AppKit menu-bar
/// popover can reopen the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
            .background(MainWindowReference())
    }
}

private struct MainWindowReference: NSViewRepresentable {
    func makeNSView(context: Context) -> ReferenceView { ReferenceView() }
    func updateNSView(_ nsView: ReferenceView, context: Context) {}

    final class ReferenceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowOpener.shared.mainWindow = window }
        }
    }
}

/// Drop-down panel hosted in the menu-bar `NSPopover` (via `NSHostingController`)
/// with live CPU / memory / disk meters and quick actions. Kept self-contained
/// so the menu bar surface stays decoupled from the main window's `AppState`.
struct MenuBarMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var processes = ProcessResourceMonitor()
    /// Which meter's heaviest apps are listed. Processes are only sampled while one is.
    @State private var listedBy: ProcessResourceSort?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text("System Monitor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 10) {
                MeterRow(title: "CPU", tint: Tint.blue,
                         fraction: monitor.cpuUsage,
                         detail: "\(Int((monitor.cpuUsage * 100).rounded()))%",
                         actionTitle: "Free Up") { toggleList(.cpu) }
                if listedBy == .cpu { heaviestApps(by: .cpu) }
                MeterRow(title: "Memory", tint: Tint.purple,
                         fraction: monitor.memoryFraction,
                         detail: byteDetail(monitor.memoryUsed, monitor.memoryTotal),
                         actionTitle: "Free Up") { toggleList(.memory) }
                if listedBy == .memory { heaviestApps(by: .memory) }
                MeterRow(title: "Disk", tint: Tint.green,
                         fraction: monitor.diskFraction,
                         detail: byteDetail(monitor.diskUsed, monitor.diskTotal),
                         actionTitle: "Clean") { cleanDisk() }
            }

            Divider()

            HStack {
                Button {
                    openMainWindow()
                } label: {
                    Text("Open PureMac")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit PureMac")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 252)
        .onChange(of: listedBy) { processes.setActive($0 != nil) }
        // The popover keeps this view mounted while closed, so onDisappear never comes.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in listedBy = nil }
        // The owning MenuBarController keeps telemetry alive for the status
        // item and popover together, and releases it explicitly on teardown.
    }

    /// Only regular apps, so the list can't offer to quit a background agent the user never sees. Memory goes back to
    /// macOS when an app quits; `purge` only empties the disk cache, which this meter doesn't count.
    @ViewBuilder
    private func heaviestApps(by sort: ProcessResourceSort) -> some View {
        let quittable = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap { $0.bundleURL?.path })
        VStack(spacing: 6) {
            ForEach(ProcessResourceMath.heaviest(processes.consumers, by: sort, quittablePaths: quittable)) { app in
                HStack(spacing: 7) {
                    if let icon = processes.icon(for: app) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(app.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(usage(of: app, by: sort))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Quit") { quit(app) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("Quit \(app.name)")
                }
            }
        }
    }

    private func usage(of app: ProcessResourceConsumer, by sort: ProcessResourceSort) -> String {
        switch sort {
        case .cpu:
            return app.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .memory:
            return ByteCountFormatter.string(fromByteCount: Int64(clamping: app.residentBytes), countStyle: .memory)
        }
    }

    private func toggleList(_ sort: ProcessResourceSort) {
        listedBy = listedBy == sort ? nil : sort
    }

    /// A polite quit: an app with unsaved work gets to ask. Never forced.
    private func quit(_ app: ProcessResourceConsumer) {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.path == app.applicationPath }
            .forEach { $0.terminate() }
    }

    /// Scans and lands on the usual review, so nothing is deleted from a click in the menu bar.
    private func cleanDisk() {
        openMainWindow()
        NotificationCenter.default.post(name: .pureMacSmartScanRequest, object: nil)
    }

    private func byteDetail(_ used: Int64, _ total: Int64) -> String {
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return "\(u) / \(t)"
    }

    /// Bring the app forward and surface the main window. The app stays alive
    /// after its window closes only while the monitor is enabled (see
    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), so this
    /// reopens a fresh window when none is left, otherwise just focuses it.
    private func openMainWindow() {
        // Transient popovers only close on an outside click, and activating the app isn't one.
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
        // Exclude the menu-bar popover's own panel; a real content window is
        // titled and can become main.
        if let existing = NSApp.windows.first(where: {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // No content window left — reopen via the captured openWindow action
            // (the popover has no working openWindow environment of its own).
            WindowOpener.shared.open?("main")
        }
    }
}

/// One labeled meter: title on the left, a thin tinted progress bar, and a
/// trailing numeric detail. Mirrors the restrained chrome used elsewhere.
private struct MeterRow: View {
    let title: LocalizedStringKey
    let tint: Color
    let fraction: Double
    let detail: String
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    private var clamped: Double { max(0, min(1, fraction)) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Spacer()
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.65)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * clamped))
                }
            }
            .frame(height: 6)
        }
    }
}
