import SwiftUI

/// FanPilot runs as an accessory (`LSUIElement`), so it is never the active
/// application when a menu bar popover closes. Windows it opens from there are
/// created behind whatever is frontmost unless the app activates itself first.
@MainActor
enum WindowPresenter {
    static func bringToFront(id: String, attempts: Int = 8) {
        NSApplication.shared.activate()
        if let window = window(with: id) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        // SwiftUI creates the window asynchronously after openWindow returns.
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            bringToFront(id: id, attempts: attempts - 1)
        }
    }

    static func window(with id: String) -> NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier?.rawValue.hasPrefix(id) == true || $0.frameAutosaveName.hasPrefix(id)
        }
    }
}

final class FanPilotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            WindowPresenter.bringToFront(id: "main")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowPresenter.bringToFront(id: "main") }
        return true
    }
}

@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(FanPilotAppDelegate.self) private var appDelegate
    @State private var monitor = FanMonitor()

    var body: some Scene {
        // A single Window rather than a WindowGroup: reopening from the menu
        // bar must focus the existing window, not spawn another copy.
        Window("FanPilot", id: "main") {
            FanMenuView(monitor: monitor)
                .frame(minWidth: 424, idealWidth: 440, maxWidth: 500)
                .padding(.vertical, 4)
        }
        .defaultSize(width: 420, height: 620)
        .windowResizability(.contentSize)

        Window("History & Diagnostics", id: "history") {
            HistoryView(monitor: monitor)
        }
        .defaultSize(width: 760, height: 760)

        MenuBarExtra {
            FanMenuView(monitor: monitor, showsWindowAction: true)
                .frame(width: 424)
                .onAppear { monitor.setPopoverVisible(true) }
                .onDisappear { monitor.setPopoverVisible(false) }
        } label: {
            // The menu bar collapses a plain Label to its icon, so the reading
            // has to be asked for explicitly.
            Label(monitor.menuTitle, systemImage: "fanblades")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
                .frame(width: 460, height: 420)
        }
    }
}
