import SwiftUI
import AppKit
import Sparkle

struct LangCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup("") {
            ContentView()
                .environmentObject(appUpdater)
        }
        .defaultSize(width: 1040, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }
}

final class AppUpdater: ObservableObject {
    private let updaterController: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        updaterController != nil
    }

    init() {
        if let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                             updaterDelegate: nil,
                                                             userDriverDelegate: nil)
        } else {
            updaterController = nil
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

/// Forces the SPM executable to behave as a normal foreground GUI app
/// (dock icon + active window) rather than a background accessory process.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
