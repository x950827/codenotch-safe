import Combine

@MainActor
final class ProviderActivityController {
    typealias SessionSink = (String, [AgentSession]) -> Void

    private let monitors: [String: any AgentActivityMonitor]
    private let onSessions: SessionSink
    private var running = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init(
        monitors: [String: any AgentActivityMonitor],
        disconnected: Set<String>,
        onSessions: @escaping SessionSink
    ) {
        self.monitors = monitors
        self.onSessions = onSessions

        for (id, monitor) in monitors {
            monitor.sessionsPublisher
                .sink { [weak self] sessions in
                    self?.onSessions(id, sessions)
                }
                .store(in: &cancellables)
        }
        apply(disconnected: disconnected)
    }

    func apply(disconnected: Set<String>) {
        for (id, monitor) in monitors {
            if disconnected.contains(id) {
                if running.remove(id) != nil {
                    monitor.stop()
                }
                onSessions(id, [])
            } else if running.insert(id).inserted {
                monitor.start()
            }
        }
    }
}
