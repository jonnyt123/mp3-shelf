import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

/// Imports Spotify *metadata* using OAuth PKCE. This service never requests audio streams.
@MainActor
final class SpotifyService: NSObject, ObservableObject {
    @Published var clientID: String {
        didSet {
            UserDefaults.standard.set(clientID, forKey: Self.clientIDKey)
            // OAuth tokens belong to the client ID that obtained them. A
            // developer-app switch must not reuse the previous app's refresh
            // token, cached playlists, or in-flight authorized requests.
            if clientID != oldValue {
                disconnect()
                message = "Spotify Client ID changed. Connect again to import playlists."
            }
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var playlists: [SpotifyPlaylist] = []
    @Published private(set) var isBusy = false
    @Published var message: String?

    private static let clientIDKey = "spotify.clientID"
    private static let redirectURI = "mp3shelf-auth://callback"
    private let keychainAccount = "spotify.oauth.tokens.v1"
    private var session: ASWebAuthenticationSession?
    private var token: SpotifyTokens?
    // Coalesce overlapping refreshes so a rotated refresh token is never reused.
    private var refreshTask: Task<SpotifyTokens, Error>?
    // A generation identifies the authorization session even if a provider
    // rotates back to the same refresh token after disconnect/reconnect.
    private var authorizationGeneration: UInt64 = 0
    // Spotify API bearer credentials must not follow an HTTP redirect to a
    // different origin. URLSession.shared follows redirects automatically.
    private let apiRedirectGuard = SpotifyAPIRedirectGuard()
    private lazy var apiSession = URLSession(configuration: .ephemeral,
                                             delegate: apiRedirectGuard,
                                             delegateQueue: nil)

    override init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        super.init()
        token = Self.loadTokens(account: keychainAccount)
        isConnected = token != nil
    }

    func signIn() async {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { message = "Enter a Spotify Developer Client ID first."; return }
        guard !isBusy else { return }
        isBusy = true
        // A disconnect or another authorization invalidates this in-flight login.
        let signInGeneration = authorizationGeneration
        // A cancelled browser may finish after a replacement sign-in has begun.
        // Its defer must not clear the replacement attempt's busy indicator.
        defer {
            if signInGeneration == authorizationGeneration { isBusy = false }
        }
        do {
            let verifier = Self.makeVerifier()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
                .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let state = UUID().uuidString
            var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: id),
                URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: challenge)
            ]
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                let browser = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "mp3shelf-auth") { url, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: SpotifyError.badCallback) }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                session = browser
                if !browser.start() { continuation.resume(throwing: SpotifyError.loginFailed) }
            }
            // Only clear the browser belonging to this authorization attempt.
            // A newer sign-in must retain its own session reference.
            guard signInGeneration == authorizationGeneration else { throw SpotifyError.notConnected }
            session = nil
            // The callback is a credential-bearing trust boundary. Reject
            // ambiguous duplicate parameters, fragments and unexpected URL
            // structure rather than trusting the first matching query item.
            // A provider error and an authorization code must never coexist.
            guard let callbackParts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  callbackParts.scheme?.lowercased() == "mp3shelf-auth",
                  callbackParts.host?.lowercased() == "callback",
                  callbackParts.path.isEmpty || callbackParts.path == "/",
                  callbackParts.user == nil, callbackParts.password == nil,
                  callbackParts.port == nil, callbackParts.fragment == nil,
                  let query = callbackParts.queryItems,
                  query.allSatisfy({ ["state", "code", "error", "error_description"].contains($0.name) }),
                  Set(query.map(\.name)).count == query.count,
                  // Exactly one terminal outcome is valid: code or error.
                  query.contains(where: { $0.name == "code" }) !=
                      query.contains(where: { $0.name == "error" }),
                  let receivedState = query.first(where: { $0.name == "state" })?.value,
                  receivedState == state else { throw SpotifyError.badCallback }
            if let error = query.first(where: { $0.name == "error" })?.value {
                throw SpotifyError.api(error)
            }
            guard let code = query.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { throw SpotifyError.badCallback }
            // Disconnect can cancel the browser while its completion is queued.
            // Do not exchange a stale authorization code or perform an OAuth
            // request after the user has explicitly revoked this sign-in.
            try Task.checkCancellation()
            guard signInGeneration == authorizationGeneration else { throw SpotifyError.notConnected }
            let newTokens = try await exchangeToken([
                "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                "client_id": id, "code_verifier": verifier
            ], oldRefresh: nil)
            // The user may have disconnected while the browser or token exchange
            // was suspended. Never resurrect credentials after that action.
            try Task.checkCancellation()
            guard signInGeneration == authorizationGeneration else {
                throw SpotifyError.notConnected
            }
            // Persist first: a Keychain failure must leave this sign-in's
            // generation intact so its defer and catch can release isBusy and
            // display the storage error. Advancing the generation beforehand
            // made the failed attempt look superseded and stranded the UI.
            try store(tokens: newTokens)
            // Only a durably saved sign-in becomes a new authorization session.
            // Invalidate stale refresh completions after persistence succeeds.
            authorizationGeneration &+= 1
            let connectedGeneration = authorizationGeneration
            isBusy = false
            do {
                try await refreshPlaylists()
            } catch {
                // A successful OAuth exchange is still a connected account.
                // Playlist access can fail independently (403, 429, network).
                // Do not hide that failure or clear a newer session's state.
                if connectedGeneration == authorizationGeneration {
                    message = error.localizedDescription
                }
            }
        } catch {
            // A superseded attempt must not clear a newer browser or publish
            // a stale error after disconnect/reconnect.
            if signInGeneration == authorizationGeneration {
                session = nil
                if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    message = error.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        authorizationGeneration &+= 1
        session?.cancel()
        session = nil
        isBusy = false
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
        playlists = []
        isConnected = false
        Self.removeTokens(account: keychainAccount)
    }

    func refreshPlaylists() async throws {
        guard token != nil else { throw SpotifyError.notConnected }
        let generation = authorizationGeneration
        var next: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")
        var found: [SpotifyPlaylist] = []
        var visitedPages = Set<URL>()
        while let url = next {
            guard visitedPages.insert(url).inserted, visitedPages.count <= 250 else {
                throw SpotifyError.api("Spotify returned repeated or excessive playlist pages.")
            }
            let page: SpotifyPage<SpotifyPlaylist> = try await request(url)
            // Account switching can occur while a page is in flight. Reject
            // its result immediately, before fetching another page using
            // credentials from the replacement account.
            try Task.checkCancellation()
            guard generation == authorizationGeneration, token != nil else {
                throw SpotifyError.notConnected
            }
            found.append(contentsOf: page.items)
            next = try Self.safeNext(page.next, for: url, returnedItems: page.rawItemCount)
            if found.count > 10000 { throw SpotifyError.api("Too many playlists to import in one request.") }
        }
        try Task.checkCancellation()
        guard generation == authorizationGeneration, token != nil else { throw SpotifyError.notConnected }
        playlists = found
    }

    /// Resolve a pasted Spotify share link using the user's authenticated
    /// playlist permissions, then the regular one-tap source-discovery flow.
    func playlistFromLink(_ value: String) async throws -> SpotifyPlaylist {
        guard token != nil else { throw SpotifyError.notConnected }
        guard let identifier = SpotifyPlaylistLinks.playlistID(from: value),
              // Share-link parsing is a separate trust boundary from API URL
              // construction. Never interpolate an unchecked path component.
              Self.isValidPlaylistID(identifier),
              let url = URL(string: "https://api.spotify.com/v1/playlists/\(identifier)")
        else {
            throw SpotifyError.api("Enter a valid open.spotify.com/playlist/… share link.")
        }
        let generation = authorizationGeneration
        let playlist: SpotifyPlaylist = try await request(url)
        // A pasted-link lookup can outlive disconnect or account switching.
        // Do not return metadata fetched under an obsolete authorization.
        try Task.checkCancellation()
        guard generation == authorizationGeneration, token != nil else {
            throw SpotifyError.notConnected
        }
        return playlist
    }

    func getTrackList(for playlist: SpotifyPlaylist) async throws -> [PlaylistWish] {
        guard token != nil else { throw SpotifyError.notConnected }
        let generation = authorizationGeneration
        // Playlist IDs are opaque Spotify base62 identifiers, never URL paths.
        // Reject malformed metadata before constructing an authenticated URL:
        // urlPathAllowed permits '/' and can otherwise change the endpoint.
        guard Self.isValidPlaylistID(playlist.id) else {
            throw SpotifyError.api("Spotify returned an invalid playlist identifier.")
        }
        var next: URL? = URL(string: "https://api.spotify.com/v1/playlists/\(playlist.id)/items?limit=50")
        var wishes: [PlaylistWish] = []
        var visitedPages = Set<URL>()
        while let url = next {
            guard visitedPages.insert(url).inserted, visitedPages.count <= 500 else {
                throw SpotifyError.api("Spotify returned repeated or excessive track pages.")
            }
            let page: SpotifyPage<SpotifyPlaylistItem> = try await request(url)
            try Task.checkCancellation()
            guard generation == authorizationGeneration, token != nil else { throw SpotifyError.notConnected }
            for entry in page.items {
                // The newer "item" envelope can be a podcast episode or a
                // redacted track even when a usable legacy "track" envelope
                // is present. Select the first *usable recording*, rather
                // than allowing a non-track item to hide a valid fallback.
                let track = [entry.item, entry.track].compactMap { $0 }.first { candidate in
                    candidate.type == "track" &&
                    !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (candidate.artists ?? []).contains {
                        !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }
                guard let track else { continue }
                // Spotify may return unavailable, partially redacted, or malformed
                // playlist entries. Never feed missing artist/title identities to
                // automatic recording discovery: a title-only match can import a
                // different artist's recording without the user noticing.
                let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let artists = (track.artists ?? []).map {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                guard !title.isEmpty, !artists.isEmpty else { continue }
                // Zero/negative durations are not usable matching evidence.
                // Keep the track but omit that evidence rather than treating
                // zero seconds as a valid full-length recording.
                let duration = track.duration_ms.flatMap { milliseconds -> Double? in
                    guard milliseconds > 0 else { return nil }
                    return Double(milliseconds) / 1000.0
                }
                wishes.append(PlaylistWish(title: title, artist: artists.joined(separator: ", "),
                    album: track.album?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    spotifyURL: SpotifyTrackLinks.canonicalURL(track.external_urls?.spotify),
                    durationSeconds: duration, artistNames: artists))
            }
            next = try Self.safeNext(page.next, for: url, returnedItems: page.rawItemCount)
            if wishes.count > 20000 { throw SpotifyError.api("The playlist contains too many tracks.") }
        }
        try Task.checkCancellation()
        guard generation == authorizationGeneration, token != nil else { throw SpotifyError.notConnected }
        if wishes.isEmpty { throw SpotifyError.api("No usable songs were returned. Spotify currently limits playlist access to playlists you own or collaborate on.") }
        return wishes
    }

    private static func isValidPlaylistID(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        // This method attaches a bearer token. Reject any unexpected URL at
        // the final dispatch boundary, including future callers that bypass
        // playlist pagination validation.
        guard let destination = URLComponents(url: url, resolvingAgainstBaseURL: false),
              destination.scheme?.lowercased() == "https",
              destination.host?.lowercased() == "api.spotify.com",
              destination.user == nil, destination.password == nil,
              destination.port == nil || destination.port == 443,
              destination.fragment == nil,
              destination.path.hasPrefix("/v1/") else {
            throw SpotifyError.api("Spotify API URL was rejected before sending credentials.")
        }
        guard token != nil else { throw SpotifyError.notConnected }
        let generation = authorizationGeneration
        try await ensureValidToken()
        // Bound both authorization replay and server-directed rate-limit retries.
        var authorizationRetries = 0
        var rateLimitRetries = 0
        var transientServerRetries = 0
        while true {
            try Task.checkCancellation()
            // ensureValidToken(), a 401 refresh, or a 429 sleep may suspend
            // this request. Never send the next page with credentials from
            // a different account that signed in while it was suspended.
            guard generation == authorizationGeneration,
                  let token else { throw SpotifyError.notConnected }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await apiSession.data(for: request)
            try Task.checkCancellation()
            guard generation == authorizationGeneration, self.token != nil else { throw SpotifyError.notConnected }
            guard let response = response as? HTTPURLResponse else { throw SpotifyError.api("No HTTP response.") }
            switch response.statusCode {
            case 200...299: return try JSONDecoder().decode(T.self, from: data)
            case 401:
                guard authorizationRetries == 0 else {
                    throw SpotifyError.api("Spotify authorization expired. Disconnect and reconnect your account.")
                }
                authorizationRetries += 1
                // Another request may already have replaced the rejected token.
                if self.token?.accessToken == token.accessToken {
                    try await refreshAccessToken()
                }
            case 403: throw SpotifyError.api("Spotify denied access to this playlist. It may not be owned by you or shared with you as a collaborator, or your Spotify account isn't allowed in this developer app.")
            case 429:
                // Retry-After may legally be zero when the rate-limit window
                // has just elapsed. Still bound immediate retries to avoid a
                // busy loop; reject long or malformed delays rather than
                // keeping a playlist import suspended indefinitely.
                guard rateLimitRetries < 2,
                      let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let seconds = Int(header), (0...10).contains(seconds) else {
                    throw SpotifyError.api("Spotify rate limit reached. Try importing again later.")
                }
                rateLimitRetries += 1
                // A zero-second provider hint still gets a short delay.
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            case 500...599:
                // Playlist metadata reads are idempotent GET requests. A
                // transient provider outage should not discard a large import
                // on the first failure, but retries must remain bounded and
                // cancellable. Never retry permanent 4xx responses here.
                guard transientServerRetries < 2 else {
                    throw SpotifyError.api("Spotify is temporarily unavailable (HTTP \(response.statusCode)). Try importing again later.")
                }
                transientServerRetries += 1
                try await Task.sleep(nanoseconds: UInt64(transientServerRetries) * 1_000_000_000)
            default: throw SpotifyError.api("Spotify request failed (HTTP \(response.statusCode)).")
            }
        }
    }

    private func ensureValidToken() async throws {
        guard let existing = token else { throw SpotifyError.notConnected }
        guard Date().addingTimeInterval(60) >= existing.expiresAt else { return }
        try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws {
        if let refreshTask {
            // The shared network task may complete before its owner persists
            // the rotated token. Every waiter must reconcile that result
            // before returning to an authenticated API request; otherwise
            // concurrent playlist pages can reuse the rejected access token.
            let generation = authorizationGeneration
            let previous = token?.refreshToken
            let fresh = try await refreshTask.value
            try Task.checkCancellation()
            guard generation == authorizationGeneration, let previous,
                  let current = token else {
                throw SpotifyError.notConnected
            }
            // The owner may already have persisted the rotated refresh
            // token. Treat that as success, not an account switch. If a
            // different token won the race, never overwrite its credentials.
            if current.accessToken == fresh.accessToken { return }
            guard current.refreshToken == previous else {
                throw SpotifyError.notConnected
            }
            try store(tokens: fresh)
            return
        }
        guard let existing = token else { throw SpotifyError.notConnected }
        let id = clientID
        let generation = authorizationGeneration
        let task = Task<SpotifyTokens, Error> {
            try await exchangeToken([
                "grant_type": "refresh_token", "refresh_token": existing.refreshToken,
                "client_id": id
            ], oldRefresh: existing.refreshToken)
        }
        refreshTask = task
        // Clear the shared task on success and failure; failed refreshes must
        // not permanently poison subsequent reconnect/retry attempts.
        defer {
            // A stale waiter must not clear a newer session's refresh task.
            if generation == authorizationGeneration { refreshTask = nil }
        }
        let fresh = try await task.value
        try Task.checkCancellation()
        // Disconnect or a new sign-in may have happened during the request.
        // A cancelled shared refresh must never restore a disconnected session.
        guard generation == authorizationGeneration,
              refreshTask != nil, token?.refreshToken == existing.refreshToken else {
            throw SpotifyError.notConnected
        }
        try store(tokens: fresh)
    }

    private func exchangeToken(_ fields: [String: String], oldRefresh: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        // The token endpoint receives authorization codes and refresh tokens.
        // Never allow a redirect to forward either credential to another host.
        // A refresh-token grant can safely be retried after a bounded 429 or
        // transient server error. Authorization codes, however, are single-use:
        // never replay an ambiguous exchange after the server may have used it.
        let isRefreshGrant = fields["grant_type"] == "refresh_token"
        var retryCount = 0
        var tokenData: Data?
        while tokenData == nil {
            try Task.checkCancellation()
            let (data, response) = try await apiSession.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyError.api("Spotify token endpoint returned no HTTP response.")
            }
            if (200...299).contains(http.statusCode) {
                tokenData = data
                break
            }
            if http.statusCode == 400 || http.statusCode == 401 {
                // Invalid or revoked refresh tokens need a new login, not
                // repeated requests that exhaust the provider's rate limits.
                throw SpotifyError.api("Spotify authorization is no longer valid. Disconnect and reconnect your account.")
            }
            guard isRefreshGrant, retryCount < 2 else {
                throw SpotifyError.api("Spotify token request failed (HTTP \(http.statusCode)). Try reconnecting if it persists.")
            }
            let delay: Int
            if http.statusCode == 429 {
                guard let value = http.value(forHTTPHeaderField: "Retry-After"),
                      let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (1...10).contains(seconds) else {
                    throw SpotifyError.api("Spotify authentication rate limit reached. Try again later.")
                }
                delay = seconds
            } else if (500...599).contains(http.statusCode) {
                // Bounded deterministic backoff; no retries on 403 or other
                // permanent client errors and no unbounded provider traffic.
                delay = retryCount + 1
            } else {
                throw SpotifyError.api("Spotify token request failed (HTTP \(http.statusCode)).")
            }
            retryCount += 1
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        guard let tokenData else { throw SpotifyError.api("Spotify token response was empty.") }
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: tokenData)
        // Do not persist an unusable token response. An empty access token or
        // nonpositive lifetime would otherwise appear connected and trigger
        // repeated refresh attempts on every playlist request.
        guard !decoded.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              // A token response with an unexpected scheme cannot be sent as
              // a Bearer credential. Older fixture responses may omit the field.
              decoded.token_type == nil || decoded.token_type?.lowercased() == "bearer",
              (1...86_400).contains(decoded.expires_in),
              let refresh = decoded.refresh_token ?? oldRefresh,
              !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpotifyError.api("Spotify returned unusable authorization credentials. Reconnect your account.")
        }
        return SpotifyTokens(accessToken: decoded.access_token, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
    }

    private func store(tokens newTokens: SpotifyTokens) throws {
        // Preserve the last recoverable refresh token until the replacement
        // is durably stored; never silently accept a failed Keychain write.
        let bytes = try JSONEncoder().encode(newTokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MP3Shelf.Spotify",
            kSecAttrAccount as String: keychainAccount
        ]
        let update: [String: Any] = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecValueData as String] = bytes
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Another Keychain writer may have inserted the same account
                // between our update and add. Retry the atomic update rather
                // than deleting the winner's credentials or reporting success
                // while leaving the new token only in memory.
                let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw SpotifyError.api("Could not securely update Spotify credentials. Try again after unlocking your device.")
                }
            } else if addStatus != errSecSuccess {
                throw SpotifyError.api("Could not securely save Spotify credentials. Reconnect and try again.")
            }
        } else if status != errSecSuccess {
            throw SpotifyError.api("Could not securely update Spotify credentials. Try again after unlocking your device.")
        }
        token = newTokens
        isConnected = true
    }

    private static func loadTokens(account: String) -> SpotifyTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MP3Shelf.Spotify", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    private static func removeTokens(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MP3Shelf.Spotify", kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { return UUID().uuidString + UUID().uuidString }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func safeNext(_ string: String?, for current: URL, returnedItems: Int) throws -> URL? {
        guard let string else { return nil }
        // An API response must not redirect our bearer token to a different
        // Spotify endpoint (including account or playlist metadata endpoints).
        // The next page must advance the cursor of this exact collection.
        // Spotify may return a relative next link. Resolve against the current
        // collection page, then apply all existing origin, path and cursor
        // restrictions to the absolute destination before attaching a token.
        // Reject scheme-relative links: even same-host forms are unnecessary.
        guard let supplied = URLComponents(string: string),
              supplied.user == nil, supplied.password == nil,
              supplied.fragment == nil,
              (supplied.scheme == nil && supplied.host == nil) ||
                  (supplied.scheme?.lowercased() == "https"),
              let resolved = URL(string: string, relativeTo: current)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let previous = URLComponents(url: current, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.spotify.com",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.fragment == nil,
              components.path == previous.path,
              let params = components.queryItems,
              params.count == 2,
              Set(params.map(\.name)) == Set(["limit", "offset"]),
              let limit = params.first(where: { $0.name == "limit" })?.value.flatMap(Int.init),
              (1...50).contains(limit),
              let offset = params.first(where: { $0.name == "offset" })?.value.flatMap(Int.init),
              let previousLimit = previous.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init),
              (1...50).contains(previousLimit),
              let previousOffset = previous.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? Optional(0),
              limit == previousLimit,
              // Spotify can return a short page while still providing a valid
              // next cursor (for example when entries are unavailable).
              // Validate continuity using the server cursor, not the number
              // of decodable items, so valid playlists are not truncated.
              // A nonterminal page with zero server slots cannot make meaningful
              // progress. Stop instead of following an unbounded chain of empty
              // pages that consumes requests without importing any tracks.
              returnedItems > 0,
              returnedItems <= previousLimit,
              previousOffset >= 0,
              previousOffset <= Int.max - limit,
              // A valid next page must not skip songs or silently change the
              // page size. Spotify supplies the immediately following offset.
              offset == previousOffset + limit,
              let url = components.url else {
            throw SpotifyError.api("Spotify returned an unexpected pagination URL.")
        }
        return url
    }
}

extension SpotifyService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession requests this on the main thread.
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
        }
    }
}

// Spotify-provided metadata is untrusted display/link data. Only expose a
// canonical Spotify track link, never an arbitrary URL from a JSON response.
enum SpotifyTrackLinks {
    static func canonicalURL(_ value: String?) -> String? {
        guard let value,
              let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "open.spotify.com",
              parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              parts.query == nil,
              parts.path.hasPrefix("/track/") else { return nil }
        let id = String(parts.path.dropFirst("/track/".count))
        guard id.utf8.count == 22,
              id.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              }) else { return nil }
        return "https://open.spotify.com/track/\(id)"
    }
}

struct SpotifyPlaylist: Identifiable, Decodable {
    let id: String
    let name: String
    let external_urls: SpotifyURLContainer?
}
struct SpotifyURLContainer: Decodable { let spotify: String? }
private struct SpotifyPage<T: Decodable>: Decodable {
    let items: [T]
    let next: String?
    // The server cursor counts every array slot, including malformed entries.
    // Never use the filtered decoded count to validate pagination bounds.
    let rawItemCount: Int

    private enum CodingKeys: String, CodingKey { case items, next }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        next = try container.decodeIfPresent(String.self, forKey: .next)
        // Spotify can return an invalid/deleted entry in the middle of an
        // otherwise valid page. Decode each entry independently instead of
        // discarding the page and all later pages on one malformed item.
        // A missing/non-array "items" is still a malformed API response.
        var entries = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [T] = []
        var rawCount = 0
        while !entries.isAtEnd {
            rawCount += 1
            // A superDecoder consumes exactly one array position even when
            // the entry's shape cannot be decoded as T.
            let entry = try entries.superDecoder()
            if let value = try? T(from: entry) {
                decoded.append(value)
            }
        }
        items = decoded
        rawItemCount = rawCount
    }
}
private struct SpotifyPlaylistItem: Decodable {
    let item: SpotifyTrack?
    let track: SpotifyTrack?

    private enum CodingKeys: String, CodingKey { case item, track }

    init(from decoder: Decoder) throws {
        // Spotify can return unavailable, deleted or partially redacted
        // playlist entries alongside valid songs. A malformed nested track
        // must not discard the entire page and every subsequent page.
        // Decode each supported envelope independently so legacy "track"
        // entries still work if the newer "item" is unusable.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try? container.decode(SpotifyTrack.self, forKey: .item)
        track = try? container.decode(SpotifyTrack.self, forKey: .track)
    }
}
private struct SpotifyTrack: Decodable {
    let name: String
    let type: String?
    let artists: [SpotifyArtist]?
    let album: SpotifyAlbum?
    let external_urls: SpotifyURLContainer?
    let duration_ms: Int?

    private enum CodingKeys: String, CodingKey {
        case name, type, artists, album, external_urls, duration_ms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing or non-string title is not a usable recording identity.
        // Optional evidence, however, can be malformed in otherwise valid
        // Spotify entries. Preserve valid artists rather than discarding the
        // entire song when one credited artist is redacted or malformed.
        name = try container.decode(String.self, forKey: .name)
        type = try? container.decode(String.self, forKey: .type)
        album = try? container.decode(SpotifyAlbum.self, forKey: .album)
        external_urls = try? container.decode(SpotifyURLContainer.self, forKey: .external_urls)
        // A negative or implausibly long duration is not reliable matching evidence.
        // Treat it as absent rather than allowing it to influence automatic
        // exact-recording selection. Spotify's duration is in milliseconds.
        if let milliseconds = try? container.decode(Int.self, forKey: .duration_ms),
           milliseconds > 0, milliseconds <= 24 * 60 * 60 * 1000 {
            duration_ms = milliseconds
        } else {
            duration_ms = nil
        }

        if var entries = try? container.nestedUnkeyedContainer(forKey: .artists) {
            var validArtists: [SpotifyArtist] = []
            while !entries.isAtEnd {
                let entry = try entries.superDecoder()
                if let artist = try? SpotifyArtist(from: entry) {
                    validArtists.append(artist)
                }
            }
            artists = validArtists
        } else {
            artists = nil
        }
    }
}
private struct SpotifyArtist: Decodable { let name: String }
private struct SpotifyAlbum: Decodable { let name: String }
private struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let token_type: String?
    let refresh_token: String?
    let expires_in: Int
}
private struct SpotifyTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}
private enum SpotifyError: LocalizedError {
    case notConnected, badCallback, loginFailed, api(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect to Spotify before importing playlists."
        case .badCallback: return "Spotify sign-in did not return a valid authorization code."
        case .loginFailed: return "Could not start the Spotify sign-in page."
        case .api(let description): return description
        }
    }
}

    
/// Refuse any redirected authenticated API request. Spotify's pagination
/// already supplies explicit next-page URLs which are separately validated.
/// Even a same-host redirect is rejected to avoid silently changing the
/// resource, path or credentials carried by an authorized request.
private final class SpotifyAPIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
