import Foundation

/// Cursor has no local usage command, so this is the one direct credential
/// boundary in the app. The session is ephemeral and cannot follow redirects.
actor CursorSafeProvider: UsageProvider {
    nonisolated let id = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let glyph = ProviderGlyph.cursor

    private let redirectDelegate: RedirectRejectingSessionDelegate?
    private let session: URLSession
    private let loadCredentials: @Sendable () throws -> CursorEditorCredentials

    init(
        session: URLSession? = nil,
        loadCredentials: @escaping @Sendable () throws -> CursorEditorCredentials = {
            try CursorEditorCredentials.load()
        }
    ) {
        if let session {
            self.redirectDelegate = nil
            self.session = session
        } else {
            let delegate = RedirectRejectingSessionDelegate()
            self.redirectDelegate = delegate
            self.session = URLSession(
                configuration: CursorEndpoint.makeConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
        self.loadCredentials = loadCredentials
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try loadCredentials()
        let request = try CursorEndpoint.makeRequest(cookie: credentials.cookieValue)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard let responseURL = http?.url, CursorEndpoint.isAllowed(responseURL) else {
            throw CursorBoundaryError.invalidEndpoint
        }
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let windows = try CursorUsage.windows(fromJSON: body)
        Log.usage.debug("cursor: status \(status), normalized windows \(windows.count)")
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: CursorUsage.headlineID(in: windows)
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: CursorEditorCredentials.bundleID, name: "Cursor")
    }

    nonisolated func account() -> ProviderAccount? {
        CursorEditorCredentials.account()
    }
}
