import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func show() {
        if let window {
            surface(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Codenotch Safe"
        window.contentView = NSHostingView(
            rootView: AboutView { [weak self] in self?.openLicense() }
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        surface(window)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.appPresence.activationPolicy)
    }

    private func surface(_ window: NSWindow) {
        if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func openLicense() {
        let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt")
            ?? AboutMetadata.licenseURL
        NSWorkspace.shared.open(url)
    }
}
