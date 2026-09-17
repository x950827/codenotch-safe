@MainActor
struct AppMenuActions {
    private let showAbout: () -> Void
    private let showSettings: () -> Void

    init(showAbout: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.showAbout = showAbout
        self.showSettings = showSettings
    }

    func openAbout() {
        showAbout()
    }

    func openSettings() {
        showSettings()
    }
}
