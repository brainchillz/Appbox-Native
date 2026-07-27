import AppBoxKit
import AppKit
import SwiftUI

@main
struct AppBoxApp: App {
    @State private var store = BoxStore()

    var body: some Scene {
        // The persistent icon by the clock. `.window` style rather than `.menu`
        // so rows can carry state dots, toggles and spinners.
        MenuBarExtra {
            MenuBarContentView(store: store)
                .frame(width: 360)
        } label: {
            MenuBarLabel(runningCount: store.runningCount, health: store.health)
        }
        .menuBarExtraStyle(.window)

        Window("AppBox", id: "manager") {
            ManagerView(store: store)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 860, height: 560)
        .windowResizability(.contentMinSize)

        Window("New Box", id: "create") {
            CreateBoxView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar icon itself. Shows a badge count of running boxes, and turns
/// into a warning symbol when the container service needs attention.
struct MenuBarLabel: View {
    let runningCount: Int
    let health: ServiceHealth

    var body: some View {
        switch health {
        case .cliMissing, .serviceStopped:
            Image(systemName: "shippingbox.trianglebadge.exclamationmark")
        case .versionSkew:
            Image(systemName: "shippingbox.trianglebadge.exclamationmark")
        case .ok:
            if runningCount > 0 {
                // Numbered box conveys "how many are up" at a glance.
                Image(systemName: "shippingbox.fill")
            } else {
                Image(systemName: "shippingbox")
            }
        }
    }
}

/// Bring the app forward when opening a window — with LSUIElement set there is
/// no Dock icon to click, so windows would otherwise open behind everything.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
