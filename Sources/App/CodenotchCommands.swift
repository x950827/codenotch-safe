import SwiftUI

struct CodenotchCommands: Commands {
    let actions: AppMenuActions

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Codenotch Safe", action: actions.openAbout)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
