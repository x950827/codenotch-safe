import Combine
import Foundation

/// Audited local builds never contact an update service. Updates are made by
/// reviewing source and rebuilding the app explicitly.
@MainActor
final class Updater: ObservableObject {
    enum Outcome: Equatable {
        case reviewedSourceOnly

        var message: String? {
            "Automatic updates are disabled. Rebuild this audited fork from reviewed source."
        }
    }

    @Published private(set) var outcome: Outcome = .reviewedSourceOnly

    var automatic: Bool {
        get { false }
        set { outcome = .reviewedSourceOnly }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var lastChecked: Date? { nil }

    func start() {}
    func checkNow() { outcome = .reviewedSourceOnly }
}
