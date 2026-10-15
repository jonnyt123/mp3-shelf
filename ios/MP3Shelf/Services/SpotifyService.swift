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
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
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
        defer { isBusy = false }
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
            session = nil
            guard callback.scheme == "mp3shelf-auth", callback.host == "callback",
                  let receivedState = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
                  receivedState == state else { throw SpotifyError.badCallback }
            let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = query.first(where: { $0.name == "error" })?.value { throw SpotifyError.api(error) }
            guard let code = query.first(where: { $0.name == "code" })?.value else { throw SpotifyError.badCallback }
            let newTokens = try await exchangeToken([
                "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                "client_id": id, "code_verifier": verifier
            ], oldRefresh: nil)
            store(tokens: newTokens)
            try await refreshPlaylists()
        } catch {
            session = nil
            if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                message = error.localizedDescription
            }
        }
    }

    func disconnect() {
        token = nil
        playlists = []
        isConnected = false
        Self.removeTokens(account: keychainAccount)
    }

    func refreshPlaylists() async throws {
        guard token != nil else { throw SpotifyError.notConnected }
        var next: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")
        var found: [SpotifyPlaylist] = []
        while let url = next {
            let page: SpotifyPage<SpotifyPlaylist> = try await request(url)
            found.append(contentsOf: page.items)
            next = try Self.safeNext(page.next)
            if found.count > 10000 { throw SpotifyError.api("Too many playlists to import in one request.") }
        }
        playlists = found
    }

    func getTrackList(for playlist: SpotifyPlaylist) async throws -> [PlaylistWish] {
        guard let encodedID = playlist.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw SpotifyError.badCallback
        }
        var next: URL? = URL(string: "https://api.spotify.com/v1/playlists/\(encodedID)/items?limit=50")
        var wishes: [PlaylistWish] = []
        while let url = next {
            let page: SpotifyPage<SpotifyPlaylistItem> = try await request(url)
            for entry in page.items {
                guard let track = entry.item ?? entry.track, track.type == "track" else { continue }
                let artist = track.artists?.map(\.name).joined(separator: ", ") ?? ""
                wishes.append(PlaylistWish(title: track.name, artist: artist,
                    album: track.album?.name ?? "", spotifyURL: track.external_urls?.spotify,
                    durationSeconds: track.duration_ms.map { Double($0) / 1000.0 }))
            }
            next = try Self.safeNext(page.next)
            if wishes.count > 20000 { throw SpotifyError.api("The playlist contains too many tracks.") }
        }
        if wishes.isEmpty { throw SpotifyError.api("No usable songs were returned. Spotify currently limits playlist access to playlists you own or collaborate on.") }
        return wishes
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        try await ensureValidToken()
        guard let token else { throw SpotifyError.notConnected }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpotifyError.api("No HTTP response.") }
        switch response.statusCode {
        case 200...299: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw SpotifyError.api("Spotify authorization expired. Disconnect and reconnect your account.")
        case 403: throw SpotifyError.api("Spotify denied access to this playlist. It may not be owned by you or shared with you as a collaborator, or your Spotify account isn't allowed in this developer app.")
        case 429: throw SpotifyError.api("Spotify rate limit reached. Try importing again later.")
        default: throw SpotifyError.api("Spotify request failed (HTTP \(response.statusCode)).")
        }
    }

    private func ensureValidToken() async throws {
        guard let existing = token else { throw SpotifyError.notConnected }
        guard Date().addingTimeInterval(60) >= existing.expiresAt else { return }
        let fresh = try await exchangeToken([
            "grant_type": "refresh_token", "refresh_token": existing.refreshToken,
            "client_id": clientID
        ], oldRefresh: existing.refreshToken)
        store(tokens: fresh)
    }

    private func exchangeToken(_ fields: [String: String], oldRefresh: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SpotifyError.api("Spotify token request failed. Check your Client ID and exact registered redirect URI.")
        }
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard let refresh = decoded.refresh_token ?? oldRefresh else { throw SpotifyError.badCallback }
        return SpotifyTokens(accessToken: decoded.access_token, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
    }

    private func store(tokens: SpotifyTokens) {
        token = tokens
        isConnected = true
        if let bytes = try? JSONEncoder().encode(tokens) {
            Self.removeTokens(account: keychainAccount)
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "MP3Shelf.Spotify",
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: bytes
            ]
            SecItemAdd(attributes as CFDictionary, nil)
        }
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

    private static func safeNext(_ string: String?) throws -> URL? {
        guard let string else { return nil }
        guard let url = URL(string: string), url.scheme == "https", url.host == "api.spotify.com" else {
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

struct SpotifyPlaylist: Identifiable, Decodable {
    let id: String
    let name: String
    let external_urls: SpotifyURLContainer?
}
struct SpotifyURLContainer: Decodable { let spotify: String? }
private struct SpotifyPage<T: Decodable>: Decodable { let items: [T]; let next: String? }
private struct SpotifyPlaylistItem: Decodable { let item: SpotifyTrack?; let track: SpotifyTrack? }
private struct SpotifyTrack: Decodable {
    let name: String
    let type: String?
    let artists: [SpotifyArtist]?
    let album: SpotifyAlbum?
    let external_urls: SpotifyURLContainer?
    let duration_ms: Int?
}
private struct SpotifyArtist: Decodable { let name: String }
private struct SpotifyAlbum: Decodable { let name: String }
private struct SpotifyTokenResponse: Decodable {
    let access_token: String
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
