import AVKit
import AppKit
import CryptoKit
import LocalAuthentication
import Network
import Security
import SwiftUI
import WebKit
import WidgetKit

private enum Constants {
    static let appName = "GoogleHomeCameraWidget"
    static let callbackPort: UInt16 = 53682
    static let redirectURI = "http://127.0.0.1:\(callbackPort)/oauth2callback"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let sdmScope = "https://www.googleapis.com/auth/sdm.service"
    static let cameraLiveStreamTrait = "sdm.devices.traits.CameraLiveStream"
    static let deviceTrait = "sdm.devices.traits.Device"
    static let infoTrait = "sdm.devices.traits.Info"
    static let structureInfoTrait = "sdm.structures.traits.Info"
    static let mockMode = ProcessInfo.processInfo.environment["CAMERA_WIDGET_USE_MOCK_CAMERAS"] == "1"
    static let backgroundSnapshotsEnabled = ProcessInfo.processInfo.environment["CAMERA_WIDGET_ENABLE_BACKGROUND_SNAPSHOTS"] == "1"
    static let previewTestId = "__video_preview_test__"
    static let previewTestURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear4/prog_index.m3u8")!
}

struct AppConfig: Decodable {
    let clientId: String?
    let clientSecret: String?
    let deviceAccessProjectId: String?
    let usePKCE: Bool?

    static func load() -> AppConfig {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Config/oauth2.local.json"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(Constants.appName)/oauth2.json")
        ]

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                continue
            }
            return config
        }

        return AppConfig(clientId: nil, clientSecret: nil, deviceAccessProjectId: nil, usePKCE: nil)
    }
}

struct OAuth2Config {
    static let fileConfig = AppConfig.load()

    static let clientId = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"] ?? fileConfig.clientId ?? ""
    static let clientSecret = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"] ?? fileConfig.clientSecret
    static let deviceAccessProjectId = ProcessInfo.processInfo.environment["GOOGLE_DEVICE_ACCESS_PROJECT_ID"] ?? fileConfig.deviceAccessProjectId ?? ""
    static let usePKCE = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_USE_PKCE"].map { $0 == "1" || $0.lowercased() == "true" } ?? fileConfig.usePKCE ?? false

    static var authorizationEndpoint: String {
        "https://nestservices.google.com/partnerconnections/\(deviceAccessProjectId)/auth"
    }
}

struct GoogleCamera: Identifiable, Equatable, Hashable {
    let id: String
    let resourceName: String
    let displayName: String
    let homeName: String
    let roomName: String?
    let brandName: String
    let supportedProtocols: [String]
    let isOnline: Bool

    var supportsRTSP: Bool { supportedProtocols.contains("RTSP") }
    var supportsWebRTC: Bool { supportedProtocols.contains("WEB_RTC") }

    var locationLabel: String {
        if let roomName, !roomName.isEmpty {
            return "\(homeName) / \(roomName)"
        }
        return homeName
    }

    var fullDisplayName: String {
        "\(locationLabel) / \(displayName)"
    }
}

enum MockCameraFactory {
    static func cameras() -> [GoogleCamera] {
        [
            GoogleCamera(
                id: "mock-webrtc-front",
                resourceName: "enterprises/mock/devices/front",
                displayName: "Front Door",
                homeName: "Main Home",
                roomName: "Entry",
                brandName: "Google Nest",
                supportedProtocols: ["WEB_RTC"],
                isOnline: true
            ),
            GoogleCamera(
                id: "mock-rtsp-back",
                resourceName: "enterprises/mock/devices/back",
                displayName: "Back Yard",
                homeName: "Main Home",
                roomName: "Patio",
                brandName: "Google Nest",
                supportedProtocols: ["RTSP"],
                isOnline: true
            ),
            GoogleCamera(
                id: "mock-nonstream-kitchen",
                resourceName: "enterprises/mock/devices/kitchen",
                displayName: "Kitchen Display",
                homeName: "Main Home",
                roomName: "Kitchen",
                brandName: "Google Nest",
                supportedProtocols: [],
                isOnline: true
            )
        ]
    }
}

enum CameraSelectionLogic {
    static func streamableCameras(from cameras: [GoogleCamera]) -> [GoogleCamera] {
        cameras.filter { $0.supportsRTSP || $0.supportsWebRTC }
    }

    static func groupedByHome(_ cameras: [GoogleCamera]) -> [(home: String, cameras: [GoogleCamera])] {
        Dictionary(grouping: cameras, by: \.homeName)
            .map { home, cameras in
                (home, cameras.sorted { $0.fullDisplayName.localizedCaseInsensitiveCompare($1.fullDisplayName) == .orderedAscending })
            }
            .sorted { $0.home.localizedCaseInsensitiveCompare($1.home) == .orderedAscending }
    }

    static func selectedCameraId(currentId: String, cameras: [GoogleCamera]) -> String {
        guard !cameras.isEmpty else { return "" }
        if cameras.contains(where: { $0.id == currentId }) {
            return currentId
        }
        return cameras[0].id
    }
}

struct AuthToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresInSeconds: Int
    let issuedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(issuedAt) > Double(expiresInSeconds)
    }

    func isAboutToExpire(threshold: TimeInterval = 300) -> Bool {
        Date().timeIntervalSince(issuedAt) > Double(expiresInSeconds) - threshold
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
}

@MainActor
final class AuthManager: ObservableObject {
    @Published var token: AuthToken?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let keychainService = Constants.appName
    private let keychainAccount = "auth_token"
    private var callbackServer: OAuthCallbackServer?
    private var codeVerifier: String?

    init() {
        if Constants.mockMode {
            token = AuthToken(accessToken: "mock-token", refreshToken: nil, expiresInSeconds: 3600, issuedAt: Date())
            isAuthenticated = true
        } else {
            loadToken()
        }
    }

    func loadToken() {
        guard let data = KeychainHelper.loadToken(service: keychainService, account: keychainAccount),
              let token = try? JSONDecoder().decode(AuthToken.self, from: data) else {
            return
        }

        self.token = token
        isAuthenticated = !token.isExpired
    }

    func authorize() {
        isLoading = true
        errorMessage = nil

        guard !OAuth2Config.clientId.isEmpty else {
            errorMessage = "Missing GOOGLE_CLIENT_ID or Config/oauth2.local.json clientId."
            isLoading = false
            return
        }

        guard !OAuth2Config.deviceAccessProjectId.isEmpty else {
            errorMessage = "Missing GOOGLE_DEVICE_ACCESS_PROJECT_ID or Config/oauth2.local.json deviceAccessProjectId."
            isLoading = false
            return
        }

        if OAuth2Config.usePKCE {
            codeVerifier = Self.makeCodeVerifier()
        } else {
            codeVerifier = nil
        }

        callbackServer = OAuthCallbackServer(port: Constants.callbackPort)
        callbackServer?.start { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let code):
                    self?.exchangeCode(for: code) { _ in }
                case .failure(let error):
                    self?.isLoading = false
                    self?.errorMessage = "OAuth callback failed: \(error.localizedDescription)"
                }
            }
        }

        var components = URLComponents(string: OAuth2Config.authorizationEndpoint)
        var queryItems = [
            URLQueryItem(name: "redirect_uri", value: Constants.redirectURI),
            URLQueryItem(name: "client_id", value: OAuth2Config.clientId),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.sdmScope)
        ]

        if let codeVerifier {
            queryItems.append(URLQueryItem(name: "code_challenge", value: Self.makeCodeChallenge(from: codeVerifier)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            errorMessage = "Failed to build Google Partner Connections Manager URL."
            isLoading = false
            return
        }

        NSWorkspace.shared.open(url)
    }

    func exchangeCode(for code: String, completion: @escaping (Result<AuthToken, Error>) -> Void) {
        isLoading = true

        guard let url = URL(string: Constants.tokenEndpoint) else {
            completion(.failure(NSError(domain: Constants.appName, code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = [
            "client_id": OAuth2Config.clientId,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": Constants.redirectURI
        ]

        if let codeVerifier {
            params["code_verifier"] = codeVerifier
        }

        if let clientSecret = OAuth2Config.clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }

        request.httpBody = Self.formBody(from: params)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isLoading = false
                    self.errorMessage = "Failed to exchange code: \(error.localizedDescription)"
                    completion(.failure(error))
                    return
                }

                guard let data else {
                    self.isLoading = false
                    self.errorMessage = "No token response from Google."
                    completion(.failure(NSError(domain: Constants.appName, code: -2)))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let response = try decoder.decode(TokenResponse.self, from: data)
                    let token = AuthToken(
                        accessToken: response.accessToken,
                        refreshToken: response.refreshToken,
                        expiresInSeconds: response.expiresIn,
                        issuedAt: Date()
                    )

                    self.token = token
                    self.isAuthenticated = true
                    self.isLoading = false
                    self.callbackServer = nil
                    self.codeVerifier = nil

                    let encodedToken = try JSONEncoder().encode(token)
                    KeychainHelper.saveToken(encodedToken, service: self.keychainService, account: self.keychainAccount)
                    completion(.success(token))
                } catch {
                    self.isLoading = false
                    self.errorMessage = Self.apiErrorMessage(prefix: "Failed to parse token response", data: data, fallback: error)
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    func validAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard let token else {
            completion(.failure(NSError(domain: Constants.appName, code: -3)))
            return
        }

        guard token.isAboutToExpire() else {
            completion(.success(token.accessToken))
            return
        }

        refreshToken { result in
            switch result {
            case .success(let token):
                completion(.success(token.accessToken))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func refreshToken(completion: @escaping (Result<AuthToken, Error>) -> Void) {
        guard let refreshToken = token?.refreshToken else {
            completion(.failure(NSError(domain: Constants.appName, code: -4)))
            return
        }

        guard let url = URL(string: Constants.tokenEndpoint) else {
            completion(.failure(NSError(domain: Constants.appName, code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = [
            "client_id": OAuth2Config.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        if let clientSecret = OAuth2Config.clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }

        request.httpBody = Self.formBody(from: params)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isAuthenticated = false
                    completion(.failure(error))
                    return
                }

                guard let data else {
                    self.isAuthenticated = false
                    completion(.failure(NSError(domain: Constants.appName, code: -2)))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let response = try decoder.decode(TokenResponse.self, from: data)
                    let newToken = AuthToken(
                        accessToken: response.accessToken,
                        refreshToken: response.refreshToken ?? self.token?.refreshToken,
                        expiresInSeconds: response.expiresIn,
                        issuedAt: Date()
                    )

                    self.token = newToken
                    self.isAuthenticated = true

                    let encodedToken = try JSONEncoder().encode(newToken)
                    KeychainHelper.saveToken(encodedToken, service: self.keychainService, account: self.keychainAccount)
                    completion(.success(newToken))
                } catch {
                    self.isAuthenticated = false
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    func signOut() {
        token = nil
        isAuthenticated = false
        KeychainHelper.deleteToken(service: keychainService, account: keychainAccount)
    }

    private static func formBody(from params: [String: String]) -> Data? {
        params
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func makeCodeVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64URLEncodedString()
    }

    private static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func apiErrorMessage(prefix: String, data: Data, fallback: Error) -> String {
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return "\(prefix): \(fallback.localizedDescription)"
        }
        return "\(prefix): \(body)"
    }
}

struct SDMDeviceResponse: Decodable, Sendable {
    let devices: [SDMDevice]
    let nextPageToken: String?
}

struct SDMStructureResponse: Decodable, Sendable {
    let structures: [SDMStructure]
    let nextPageToken: String?
}

struct SDMDevice: Decodable, Sendable {
    let name: String
    let type: String?
    let traits: [String: JSONValue]?
    let parentRelations: [ParentRelation]?
}

struct ParentRelation: Decodable, Sendable {
    let parent: String?
    let displayName: String?
}

struct SDMStructure: Decodable, Sendable {
    let name: String
    let traits: [String: JSONValue]?
    let parentRelations: [ParentRelation]?
}

struct GenerateRTSPStreamResponse: Decodable {
    let results: RTSPStreamResults
}

struct GenerateWebRTCStreamResponse: Decodable {
    let results: WebRTCStreamResults
}

struct RTSPStreamResults: Decodable {
    let streamUrls: [String: String]?
    let streamExtensionToken: String?
    let streamToken: String?
    let expiresAt: String?
}

struct WebRTCStreamResults: Decodable {
    let answerSdp: String
    let mediaSessionId: String?
    let expiresAt: String?
}

struct SnapshotMetadata: Codable {
    let cameraId: String
    let cameraName: String
    let homeName: String
    let roomName: String?
    let updatedAt: Date
}

enum SnapshotStore {
    static let widgetKind = "GoogleHomeCameraSnapshotWidget"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GoogleHomeCameraWidget", isDirectory: true)
    }

    static var catalogURL: URL {
        directory.appendingPathComponent("camera-catalog.json")
    }

    static func imageURL(for cameraId: String) -> URL {
        directory.appendingPathComponent("latest-snapshot-\(fileToken(for: cameraId)).png")
    }

    static func metadataURL(for cameraId: String) -> URL {
        directory.appendingPathComponent("latest-snapshot-\(fileToken(for: cameraId)).json")
    }

    static func write(image: NSImage, camera: GoogleCamera) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: Constants.appName, code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to encode snapshot image."])
        }

        try png.write(to: imageURL(for: camera.id), options: .atomic)

        let metadata = SnapshotMetadata(
            cameraId: camera.id,
            cameraName: camera.displayName,
            homeName: camera.homeName,
            roomName: camera.roomName,
            updatedAt: Date()
        )
        let encodedMetadata = try JSONEncoder().encode(metadata)
        try encodedMetadata.write(to: metadataURL(for: camera.id), options: .atomic)

        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    static func writeCatalog(cameras: [GoogleCamera]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalog = cameras.map {
            CameraCatalogEntry(
                id: $0.id,
                cameraName: $0.displayName,
                homeName: $0.homeName,
                roomName: $0.roomName
            )
        }
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: catalogURL, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    private static func fileToken(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CameraCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let cameraName: String
    let homeName: String
    let roomName: String?

    var displayName: String {
        if let roomName, !roomName.isEmpty {
            return "\(homeName) / \(roomName) / \(cameraName)"
        }
        return "\(homeName) / \(cameraName)"
    }
}

final class SnapshotSource {
    static let shared = SnapshotSource()
    weak var view: NSView?
}

@MainActor
final class SnapshotScheduler: ObservableObject {
    static let shared = SnapshotScheduler()

    @Published private(set) var status = "Snapshot scheduler idle"

    private var workers: [String: CameraSnapshotWorker] = [:]

    func start(cameras: [GoogleCamera], authManager: AuthManager) {
        let cameraIds = Set(cameras.map(\.id))

        for (id, worker) in workers where !cameraIds.contains(id) {
            worker.stop()
            workers[id] = nil
        }

        for (index, camera) in cameras.enumerated() {
            guard camera.supportsRTSP || camera.supportsWebRTC else { continue }

            if let worker = workers[camera.id] {
                worker.update(camera: camera)
            } else {
                let worker = CameraSnapshotWorker(camera: camera, authManager: authManager)
                workers[camera.id] = worker
                worker.start(initialDelay: TimeInterval(index * 5))
            }
        }

        status = workers.isEmpty
            ? "No stream-capable cameras available for widget snapshots"
            : "Updating \(workers.count) camera widget snapshot\(workers.count == 1 ? "" : "s") every 60 seconds"
    }

    func stopAll() {
        workers.values.forEach { $0.stop() }
        workers.removeAll()
        status = "Snapshot scheduler stopped"
    }
}

@MainActor
final class CameraSnapshotWorker {
    private var camera: GoogleCamera
    private weak var authManager: AuthManager?
    private var timer: Timer?
    private var hiddenWindow: NSWindow?
    private var webRTCSession: HiddenWebRTCSession?

    init(camera: GoogleCamera, authManager: AuthManager) {
        self.camera = camera
        self.authManager = authManager
    }

    func update(camera: GoogleCamera) {
        self.camera = camera
    }

    func start(initialDelay: TimeInterval) {
        stopTimerOnly()

        guard initialDelay > 0 else {
            capture()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.capture()
                }
            }
            return
        }

        Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.capture()
                self?.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.capture()
                    }
                }
            }
        }
    }

    func stop() {
        stopTimerOnly()
        webRTCSession?.stop()
        webRTCSession = nil
        hiddenWindow?.close()
        hiddenWindow = nil
    }

    private func stopTimerOnly() {
        timer?.invalidate()
        timer = nil
    }

    private func capture() {
        guard let authManager else { return }

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let accessToken):
                    if self.camera.supportsWebRTC {
                        self.captureWebRTC(accessToken: accessToken)
                    } else if self.camera.supportsRTSP {
                        self.captureRTSP(accessToken: accessToken)
                    }
                case .failure:
                    break
                }
            }
        }
    }

    private func captureRTSP(accessToken: String) {
        executeStreamCommand(
            command: "sdm.devices.commands.CameraLiveStream.GenerateRtspStream",
            params: [:],
            accessToken: accessToken
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                guard case .success(let data) = result,
                      let response = try? JSONDecoder().decode(GenerateRTSPStreamResponse.self, from: data),
                      let urlString = response.results.streamUrls?["rtspUrl"],
                      let url = URL(string: urlString) else {
                    return
                }

                let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
                playerView.controlsStyle = .none
                playerView.videoGravity = .resizeAspect
                playerView.player = AVPlayer(url: url)
                self.installHidden(view: playerView)
                playerView.player?.play()

                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard let image = playerView.snapshotImage() else { return }
                    try? SnapshotStore.write(image: image, camera: self.camera)
                    playerView.player?.pause()
                }
            }
        }
    }

    private func captureWebRTC(accessToken: String) {
        webRTCSession?.stop()
        let session = HiddenWebRTCSession(camera: camera) { [weak self] offerSdp in
            self?.executeStreamCommand(
                command: "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream",
                params: ["offerSdp": offerSdp],
                accessToken: accessToken
            ) { [weak self] result in
                Task { @MainActor in
                    guard case .success(let data) = result,
                          let response = try? JSONDecoder().decode(GenerateWebRTCStreamResponse.self, from: data) else {
                        return
                    }

                    self?.webRTCSession?.apply(answerSdp: response.results.answerSdp)
                }
            }
        } onSnapshot: { camera, image in
            try? SnapshotStore.write(image: image, camera: camera)
        }
        webRTCSession = session
        installHidden(view: session.webView)
        session.start()
    }

    private func executeStreamCommand(
        command: String,
        params: [String: Any],
        accessToken: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/\(camera.resourceName):executeCommand"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: Constants.appName, code: -20)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "params": params])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data else {
                completion(.failure(NSError(domain: Constants.appName, code: -21)))
                return
            }

            completion(.success(data))
        }.resume()
    }

    private func installHidden(view: NSView) {
        let window: NSWindow
        if let hiddenWindow {
            window = hiddenWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.orderBack(nil)
            hiddenWindow = window
        }

        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        window.contentView = view
    }
}

@MainActor
final class HiddenWebRTCSession: NSObject, WKScriptMessageHandler {
    let webView: WKWebView

    private let camera: GoogleCamera
    private let onOffer: (String) -> Void
    private let onSnapshot: (GoogleCamera, NSImage) -> Void
    private var appliedAnswerSdp: String?
    private var capturedForCurrentAnswer = false

    init(camera: GoogleCamera, onOffer: @escaping (String) -> Void, onSnapshot: @escaping (GoogleCamera, NSImage) -> Void) {
        self.camera = camera
        self.onOffer = onOffer
        self.onSnapshot = onSnapshot

        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)
        super.init()

        contentController.add(self, name: "native")
        webView.setValue(false, forKey: "drawsBackground")
    }

    func start() {
        capturedForCurrentAnswer = false
        webView.loadHTMLString(WebRTCPlayerView.html, baseURL: URL(string: "https://localhost"))
    }

    func apply(answerSdp: String) {
        guard appliedAnswerSdp != answerSdp else { return }
        appliedAnswerSdp = answerSdp

        do {
            let data = try JSONSerialization.data(withJSONObject: answerSdp)
            guard let encoded = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.applyAnswer(\(encoded));")
        } catch {
            return
        }
    }

    func stop() {
        webView.evaluateJavaScript("window.stopStream && window.stopStream();")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "offer":
            guard let sdp = body["sdp"] as? String else { return }
            onOffer(sdp)
        case "status":
            guard !capturedForCurrentAnswer,
                  let message = body["message"] as? String,
                  message.contains("connected") || message.contains("Waiting for media") else {
                return
            }
            capturedForCurrentAnswer = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let image = self.webView.snapshotImage() else { return }
                self.onSnapshot(self.camera, image)
            }
        default:
            break
        }
    }
}

@MainActor
final class LiveFeedCoordinator: ObservableObject {
    private var models: [String: LiveFeedModel] = [:]

    func model(for camera: GoogleCamera) -> LiveFeedModel {
        if let model = models[camera.id] {
            model.update(camera: camera)
            return model
        }

        let model = LiveFeedModel(camera: camera)
        models[camera.id] = model
        return model
    }

    func reset() {
        models.values.forEach { $0.stop() }
        models.removeAll()
    }
}

@MainActor
final class BroadcastBridgeController: ObservableObject {
    private var models: [String: LiveFeedModel] = [:]
    private var window: NSWindow?

    func model(for camera: GoogleCamera) -> LiveFeedModel {
        if let model = models[camera.id] {
            model.update(camera: camera)
            return model
        }

        let model = LiveFeedModel(camera: camera)
        models[camera.id] = model
        return model
    }

    func openWindow(camera: GoogleCamera, authManager: AuthManager) {
        let model = model(for: camera)
        let rootView = BroadcastFeedWindowView(camera: camera, model: model, authManager: authManager)
        let hostingView = NSHostingView(rootView: rootView)

        let outputWindow: NSWindow
        if let window {
            outputWindow = window
        } else {
            outputWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            outputWindow.minSize = NSSize(width: 640, height: 360)
            outputWindow.collectionBehavior = [.fullScreenAuxiliary]
            outputWindow.isReleasedWhenClosed = false
            window = outputWindow
        }

        outputWindow.title = "Nest Broadcast Feed - \(camera.displayName)"
        outputWindow.contentAspectRatio = NSSize(width: 16, height: 9)
        outputWindow.contentView = hostingView
        outputWindow.center()
        outputWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start(authManager: authManager)
    }
}

@MainActor
final class LiveFeedModel: ObservableObject {
    @Published var rtspURL: URL?
    @Published var webRTCAnswerSdp: String?
    @Published var status: String?
    @Published var errorMessage: String?

    private(set) var camera: GoogleCamera
    private var isStarted = false
    private var webRTCTimeoutTask: Task<Void, Never>?

    init(camera: GoogleCamera) {
        self.camera = camera
    }

    func update(camera: GoogleCamera) {
        guard self.camera.id != camera.id else {
            self.camera = camera
            return
        }

        stop()
        self.camera = camera
    }

    func start(authManager: AuthManager) {
        guard !isStarted else { return }
        isStarted = true
        errorMessage = nil

        if Constants.mockMode {
            status = "Mock stream ready."
        } else if camera.supportsRTSP {
            status = "Starting RTSP..."
            authManager.validAccessToken { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let accessToken):
                        self.generateRTSP(accessToken: accessToken)
                    case .failure(let error):
                        self.status = nil
                        self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                    }
                }
            }
        } else if camera.supportsWebRTC {
            status = "Starting WebRTC..."
        } else {
            status = nil
            errorMessage = "No supported stream protocol."
        }
    }

    func stop() {
        webRTCTimeoutTask?.cancel()
        webRTCTimeoutTask = nil
        isStarted = false
        rtspURL = nil
        webRTCAnswerSdp = nil
        status = nil
        errorMessage = nil
    }

    func generateWebRTC(offerSdp: String, authManager: AuthManager) {
        guard camera.supportsWebRTC else { return }
        status = "Requesting WebRTC answer..."
        errorMessage = nil
        webRTCTimeoutTask?.cancel()
        webRTCTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await MainActor.run {
                guard let self, self.webRTCAnswerSdp == nil, self.errorMessage == nil else { return }
                self.status = nil
                self.errorMessage = "Timed out waiting for Google's WebRTC answer. Try Refresh, then select this camera again."
            }
        }

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let accessToken):
                    self.executeCommand(
                        command: "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream",
                        params: ["offerSdp": offerSdp],
                        accessToken: accessToken
                    ) { [weak self] result in
                        Task { @MainActor in
                            guard let self else { return }
                            switch result {
                            case .success(let data):
                                do {
                                    let response = try JSONDecoder().decode(GenerateWebRTCStreamResponse.self, from: data)
                                    self.webRTCTimeoutTask?.cancel()
                                    self.webRTCTimeoutTask = nil
                                    self.webRTCAnswerSdp = response.results.answerSdp
                                    self.status = "Applying WebRTC answer..."
                                } catch {
                                    self.webRTCTimeoutTask?.cancel()
                                    self.webRTCTimeoutTask = nil
                                    self.status = nil
                                    self.errorMessage = "Failed to parse WebRTC response: \(error.localizedDescription)"
                                }
                            case .failure(let error):
                                self.webRTCTimeoutTask?.cancel()
                                self.webRTCTimeoutTask = nil
                                self.status = nil
                                self.errorMessage = "WebRTC command failed: \(error.localizedDescription)"
                            }
                        }
                    }
                case .failure(let error):
                    self.webRTCTimeoutTask?.cancel()
                    self.webRTCTimeoutTask = nil
                    self.status = nil
                    self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func generateRTSP(accessToken: String) {
        executeCommand(
            command: "sdm.devices.commands.CameraLiveStream.GenerateRtspStream",
            params: [:],
            accessToken: accessToken
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let data):
                    do {
                        let response = try JSONDecoder().decode(GenerateRTSPStreamResponse.self, from: data)
                        guard let urlString = response.results.streamUrls?["rtspUrl"],
                              let url = URL(string: urlString) else {
                            self.status = nil
                            self.errorMessage = "RTSP command succeeded, but no stream URL was returned."
                            return
                        }
                        self.rtspURL = url
                        self.status = nil
                    } catch {
                        self.status = nil
                        self.errorMessage = "Failed to parse RTSP response: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.status = nil
                    self.errorMessage = "RTSP command failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func executeCommand(
        command: String,
        params: [String: Any],
        accessToken: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/\(camera.resourceName):executeCommand"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: Constants.appName, code: -30)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "params": params])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, let data else {
                completion(.failure(NSError(domain: Constants.appName, code: -31, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from stream command."])))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "No response body."
                completion(.failure(NSError(domain: Constants.appName, code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"])))
                return
            }

            completion(.success(data))
        }.resume()
    }
}

enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}

@MainActor
final class CameraManager: ObservableObject {
    @Published var cameras: [GoogleCamera] = []
    @Published var selectedCamera: GoogleCamera?
    @Published var rtspURL: URL?
    @Published var webRTCAnswerSdp: String?
    @Published var webRTCStatus: String?
    @Published var streamExpiresAt: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var discoverySummary: String?

    @AppStorage("selectedCameraId") private var storedSelection: String?

    func loadCameras(authManager: AuthManager) {
        isLoading = true
        errorMessage = nil
        rtspURL = nil
        webRTCAnswerSdp = nil
        webRTCStatus = nil
        discoverySummary = nil

        if Constants.mockMode {
            cameras = MockCameraFactory.cameras()
            selectedCamera = cameras.first
            discoverySummary = "Mock SDM returned \(cameras.count) devices; \(CameraSelectionLogic.streamableCameras(from: cameras).count) include camera live-stream support."
            try? SnapshotStore.writeCatalog(cameras: cameras)
            isLoading = false
            return
        }

        guard !OAuth2Config.deviceAccessProjectId.isEmpty else {
            isLoading = false
            errorMessage = "Configure your Google Device Access project ID before loading cameras."
            return
        }

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let accessToken):
                    self?.fetchCameras(with: accessToken, authManager: authManager)
                case .failure(let error):
                    self?.isLoading = false
                    self?.errorMessage = "Authentication failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func generateRTSPStream(authManager: AuthManager) {
        guard let selectedCamera else {
            errorMessage = "Select a camera first."
            return
        }

        guard selectedCamera.supportsRTSP else {
            errorMessage = "This camera does not report RTSP support."
            return
        }

        isLoading = true
        errorMessage = nil
        webRTCAnswerSdp = nil
        webRTCStatus = nil

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let accessToken):
                    self?.executeRTSPCommand(for: selectedCamera, accessToken: accessToken)
                case .failure(let error):
                    self?.isLoading = false
                    self?.errorMessage = "Authentication failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func generateWebRTCStream(authManager: AuthManager, offerSdp: String) {
        guard let selectedCamera else {
            errorMessage = "Select a camera first."
            return
        }

        guard selectedCamera.supportsWebRTC else {
            errorMessage = "This camera does not report WebRTC support."
            return
        }

        isLoading = true
        errorMessage = nil
        rtspURL = nil
        webRTCStatus = "Requesting WebRTC answer from Google..."

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let accessToken):
                    self?.executeWebRTCCommand(for: selectedCamera, offerSdp: offerSdp, accessToken: accessToken)
                case .failure(let error):
                    self?.isLoading = false
                    self?.webRTCStatus = nil
                    self?.errorMessage = "Authentication failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func selectCamera(_ camera: GoogleCamera) {
        storedSelection = camera.id
        selectedCamera = camera
        rtspURL = nil
        webRTCAnswerSdp = nil
        webRTCStatus = nil
        streamExpiresAt = nil
    }

    private func fetchCameras(with accessToken: String, authManager: AuthManager) {
        fetchStructures(with: accessToken) { [weak self] structuresByName in
            Task { @MainActor in
                guard let self else { return }
                self.fetchDevices(with: accessToken, structuresByName: structuresByName, authManager: authManager)
            }
        }
    }

    private func fetchStructures(with accessToken: String, completion: @escaping ([String: String]) -> Void) {
        guard let url = URL(string: "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(OAuth2Config.deviceAccessProjectId)/structures") else {
            completion([:])
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data,
                  let root = try? JSONDecoder().decode(SDMStructureResponse.self, from: data) else {
                completion([:])
                return
            }

            let structures = Dictionary(uniqueKeysWithValues: root.structures.map { structure in
                (structure.name, Self.structureDisplayName(from: structure))
            })
            completion(structures)
        }.resume()
    }

    private func fetchDevices(
        with accessToken: String,
        structuresByName: [String: String],
        authManager: AuthManager
    ) {
        guard let url = URL(string: "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(OAuth2Config.deviceAccessProjectId)/devices") else {
            isLoading = false
            errorMessage = "Invalid Device Access API URL."
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isLoading = false
                    self.errorMessage = "Device Access API error: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, let data else {
                    self.isLoading = false
                    self.errorMessage = "No response from Device Access API."
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    self.isLoading = false
                    self.errorMessage = Self.apiErrorMessage("Device Access API returned HTTP \(httpResponse.statusCode)", data: data)
                    return
                }

                do {
                    let root = try JSONDecoder().decode(SDMDeviceResponse.self, from: data)
                    self.cameras = root.devices
                        .compactMap { Self.camera(from: $0, structuresByName: structuresByName) }
                        .sorted { $0.fullDisplayName.localizedCaseInsensitiveCompare($1.fullDisplayName) == .orderedAscending }
                    self.discoverySummary = "SDM returned \(root.devices.count) device\(root.devices.count == 1 ? "" : "s"); \(self.cameras.count) include camera live-stream support."

                    if let storedId = self.storedSelection,
                       let camera = self.cameras.first(where: { $0.id == storedId }) {
                        self.selectedCamera = camera
                    } else {
                        self.selectedCamera = self.cameras.first
                    }

                    if self.cameras.isEmpty {
                        self.errorMessage = "No authorized SDM cameras were returned. Check Partner Connections Manager permissions."
                    }

                    try? SnapshotStore.writeCatalog(cameras: self.cameras)
                    if Constants.backgroundSnapshotsEnabled {
                        SnapshotScheduler.shared.start(cameras: self.cameras, authManager: authManager)
                    } else {
                        SnapshotScheduler.shared.stopAll()
                    }
                    self.isLoading = false
                } catch {
                    self.isLoading = false
                    self.errorMessage = "Failed to parse Device Access response: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func executeRTSPCommand(for camera: GoogleCamera, accessToken: String) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/\(camera.resourceName):executeCommand"
        guard let url = URL(string: urlString) else {
            isLoading = false
            errorMessage = "Invalid stream command URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        {"command":"sdm.devices.commands.CameraLiveStream.GenerateRtspStream","params":{}}
        """.utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isLoading = false
                    self.errorMessage = "Stream command failed: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, let data else {
                    self.isLoading = false
                    self.errorMessage = "No response from stream command."
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    self.isLoading = false
                    self.errorMessage = Self.apiErrorMessage("Stream command returned HTTP \(httpResponse.statusCode)", data: data)
                    return
                }

                do {
                    let response = try JSONDecoder().decode(GenerateRTSPStreamResponse.self, from: data)
                    guard let urlString = response.results.streamUrls?["rtspUrl"],
                          let url = URL(string: urlString) else {
                        self.isLoading = false
                        self.errorMessage = "Stream command succeeded, but no RTSP URL was returned."
                        return
                    }

                    self.rtspURL = url
                    self.webRTCAnswerSdp = nil
                    self.webRTCStatus = nil
                    self.streamExpiresAt = response.results.expiresAt
                    self.isLoading = false
                } catch {
                    self.isLoading = false
                    self.errorMessage = "Failed to parse stream response: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func executeWebRTCCommand(for camera: GoogleCamera, offerSdp: String, accessToken: String) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/\(camera.resourceName):executeCommand"
        guard let url = URL(string: urlString) else {
            isLoading = false
            webRTCStatus = nil
            errorMessage = "Invalid stream command URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "command": "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream",
                "params": ["offerSdp": offerSdp]
            ])
        } catch {
            isLoading = false
            webRTCStatus = nil
            errorMessage = "Failed to encode WebRTC offer: \(error.localizedDescription)"
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isLoading = false
                    self.webRTCStatus = nil
                    self.errorMessage = "WebRTC command failed: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, let data else {
                    self.isLoading = false
                    self.webRTCStatus = nil
                    self.errorMessage = "No response from WebRTC command."
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    self.isLoading = false
                    self.webRTCStatus = nil
                    self.errorMessage = Self.apiErrorMessage("WebRTC command returned HTTP \(httpResponse.statusCode)", data: data)
                    return
                }

                do {
                    let response = try JSONDecoder().decode(GenerateWebRTCStreamResponse.self, from: data)
                    self.webRTCAnswerSdp = response.results.answerSdp
                    self.streamExpiresAt = response.results.expiresAt
                    self.webRTCStatus = "Applying Google WebRTC answer..."
                    self.isLoading = false
                } catch {
                    self.isLoading = false
                    self.webRTCStatus = nil
                    self.errorMessage = "Failed to parse WebRTC response: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private static func camera(from device: SDMDevice, structuresByName: [String: String]) -> GoogleCamera? {
        guard let traits = device.traits,
              let streamTrait = traits[Constants.cameraLiveStreamTrait] else {
            return nil
        }

        let protocols = streamTrait["supportedProtocols"]?.stringArray ?? []
        let infoTrait = traits[Constants.infoTrait]
        let deviceTrait = traits[Constants.deviceTrait]
        let customName = infoTrait?["customName"]?.stringValue
        let relation = device.parentRelations?.first
        let structureResourceName = structureResourceName(from: relation?.parent)
        let relationIsRoom = relation?.parent?.contains("/rooms/") == true
        let roomName = relationIsRoom ? relation?.displayName : nil
        let homeName = structureResourceName.flatMap { structuresByName[$0] }
            ?? (!relationIsRoom ? relation?.displayName : nil)
            ?? fallbackHomeName(from: structureResourceName)
        let online = deviceTrait?["connectivity"]?["status"]?.stringValue == "ONLINE"

        return GoogleCamera(
            id: device.name,
            resourceName: device.name,
            displayName: customName ?? roomName ?? device.name.components(separatedBy: "/").last ?? "Camera",
            homeName: homeName,
            roomName: roomName,
            brandName: "Google Nest",
            supportedProtocols: protocols,
            isOnline: online
        )
    }

    nonisolated private static func structureDisplayName(from structure: SDMStructure) -> String {
        structure.traits?[Constants.structureInfoTrait]?["customName"]?.stringValue
            ?? structure.parentRelations?.first?.displayName
            ?? fallbackHomeName(from: structure.name)
    }

    nonisolated private static func structureResourceName(from parent: String?) -> String? {
        guard let parent,
              let range = parent.range(of: #"/structures/[^/]+"#, options: .regularExpression) else {
            return nil
        }

        let prefix = parent[..<range.upperBound]
        return String(prefix)
    }

    nonisolated private static func fallbackHomeName(from structureResourceName: String?) -> String {
        guard let structureResourceName,
              let suffix = structureResourceName.components(separatedBy: "/").last,
              !suffix.isEmpty else {
            return "Unknown Home"
        }
        return "Home \(suffix)"
    }

    private static func apiErrorMessage(_ prefix: String, data: Data) -> String {
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return prefix
        }
        return "\(prefix): \(body)"
    }
}

struct CameraView: View {
    @StateObject private var authManager = AuthManager()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var liveFeedCoordinator = LiveFeedCoordinator()
    @ObservedObject private var snapshotScheduler = SnapshotScheduler.shared
    @State private var selectedCameraId = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if authManager.isLoading || cameraManager.isLoading {
                loadingView
            } else if !authManager.isAuthenticated {
                authenticationView
            } else if streamableCameras.isEmpty {
                emptyCameraView
            } else {
                singleCameraView
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 560)
        .onAppear {
            if authManager.isAuthenticated {
                cameraManager.loadCameras(authManager: authManager)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Nest Camera Viewer", systemImage: "video")
                .font(.headline)
            Spacer()
            if authManager.isAuthenticated {
                HeaderAction(title: "Refresh", systemImage: "arrow.clockwise") {
                    liveFeedCoordinator.reset()
                    cameraManager.loadCameras(authManager: authManager)
                }

                HeaderAction(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    liveFeedCoordinator.reset()
                    SnapshotScheduler.shared.stopAll()
                    authManager.signOut()
                }
            }
        }
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Contacting Google...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var authenticationView: some View {
        VStack(spacing: 18) {
            Image(systemName: "key")
                .font(.system(size: 52))
                .foregroundColor(.accentColor)
            Text("Connect Google Nest Device Access")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Uses your local OAuth client and Device Access project. Tokens are stored in macOS Keychain.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            errorText

            HeaderAction(title: "Sign In with Google", systemImage: "person.crop.circle.badge.checkmark") {
                authManager.authorize()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCameraView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No streamable cameras found")
                .font(.title3)
                .fontWeight(.semibold)
            Text(cameraManager.discoverySummary ?? "Only cameras that report RTSP or WebRTC support are selectable.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            errorText
            HeaderAction(title: "Load Cameras", systemImage: "arrow.clockwise") {
                cameraManager.loadCameras(authManager: authManager)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var singleCameraView: some View {
        HStack(spacing: 0) {
            cameraSelectionStrip
            Divider()
            if let camera = selectedCamera {
                CameraFeedTile(
                    camera: camera,
                    model: liveFeedCoordinator.model(for: camera),
                    authManager: authManager,
                    isZoomed: true
                )
                .id(camera.id)
                .padding(12)
            } else {
                ContentUnavailableView("Select a streamable camera", systemImage: "video")
            }
        }
        .onAppear(perform: selectDefaultCameraIfNeeded)
        .onChange(of: cameraManager.cameras) {
            selectDefaultCameraIfNeeded()
        }
        .onChange(of: selectedCameraId) {
            liveFeedCoordinator.reset()
        }
    }

    private var cameraSelectionStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cameraManager.discoverySummary ?? "\(streamableCameras.count) streamable camera\(streamableCameras.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)

            CameraSelectionTable(cameras: streamableCameras, selectedCameraId: $selectedCameraId)

            Divider()

                Text(Constants.backgroundSnapshotsEnabled ? snapshotScheduler.status : "Widget snapshot updates paused while live preview is active")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
        }
        .frame(width: 220)
        .padding(10)
    }

    private var streamableCameras: [GoogleCamera] {
        CameraSelectionLogic.streamableCameras(from: cameraManager.cameras)
    }

    private var selectedCamera: GoogleCamera? {
        streamableCameras.first { $0.id == selectedCameraId } ?? streamableCameras.first
    }

    private var groupedStreamableCameras: [(home: String, cameras: [GoogleCamera])] {
        CameraSelectionLogic.groupedByHome(streamableCameras)
    }

    private func selectDefaultCameraIfNeeded() {
        selectedCameraId = CameraSelectionLogic.selectedCameraId(currentId: selectedCameraId, cameras: streamableCameras)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = authManager.errorMessage ?? cameraManager.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    private func protocolSummary(for camera: GoogleCamera) -> String {
        camera.supportedProtocols.isEmpty
            ? "No stream protocols reported by SDM."
            : "Protocols: \(camera.supportedProtocols.joined(separator: ", "))"
    }
}

struct HeaderAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        AppKitActionButton(title: title, systemImage: systemImage, action: action)
            .frame(height: 34)
    }
}

struct AppKitActionButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performAction))
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

private enum CameraSelectionRow {
    case section(String)
    case camera(GoogleCamera)

    var isSelectable: Bool {
        switch self {
        case .camera:
            return true
        case .section:
            return false
        }
    }

    var selectionId: String? {
        switch self {
        case .camera(let camera):
            return camera.id
        case .section:
            return nil
        }
    }
}

struct CameraSelectionTable: NSViewRepresentable {
    let cameras: [GoogleCamera]
    @Binding var selectedCameraId: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedCameraId: $selectedCameraId)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowAction(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("camera"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.update(cameras: cameras, selectedCameraId: selectedCameraId)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(cameras: cameras, selectedCameraId: selectedCameraId)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        @Binding private var selectedCameraId: String
        weak var tableView: NSTableView?
        private var rows: [CameraSelectionRow] = []
        private var isProgrammaticSelection = false

        init(selectedCameraId: Binding<String>) {
            _selectedCameraId = selectedCameraId
        }

        func update(cameras: [GoogleCamera], selectedCameraId: String) {
            rows = []
            for group in CameraSelectionLogic.groupedByHome(cameras) {
                rows.append(.section(group.home))
                rows.append(contentsOf: group.cameras.map { .camera($0) })
            }

            tableView?.reloadData()
            selectRow(for: selectedCameraId)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].isSelectable
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            commitSelection()
        }

        @objc func rowAction(_ sender: NSTableView) {
            commitSelection()
        }

        private func commitSelection() {
            guard !isProgrammaticSelection,
                  let tableView,
                  rows.indices.contains(tableView.selectedRow),
                  let id = rows[tableView.selectedRow].selectionId else {
                return
            }

            selectedCameraId = id
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("CameraSelectionCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            cell.subviews.forEach { $0.removeFromSuperview() }

            let textField = NSTextField(labelWithString: title(for: rows[row]))
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 2
            textField.font = font(for: rows[row])
            textField.textColor = textColor(for: rows[row])
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func selectRow(for id: String) {
            guard let tableView else { return }
            let row = rows.firstIndex { $0.selectionId == id } ?? rows.firstIndex { $0.selectionId != nil }

            isProgrammaticSelection = true
            if let row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
            isProgrammaticSelection = false
        }

        private func title(for row: CameraSelectionRow) -> String {
            switch row {
            case .section(let home):
                return home
            case .camera(let camera):
                let room = camera.roomName?.isEmpty == false ? camera.roomName! : "Unassigned Room"
                return "\(camera.displayName)\n\(room)"
            }
        }

        private func font(for row: CameraSelectionRow) -> NSFont {
            switch row {
            case .section:
                return .systemFont(ofSize: 12, weight: .semibold)
            case .camera:
                return .systemFont(ofSize: 13, weight: .regular)
            }
        }

        private func textColor(for row: CameraSelectionRow) -> NSColor {
            switch row {
            case .section:
                return .secondaryLabelColor
            case .camera:
                return .labelColor
            }
        }
    }
}

enum AppSurface: String, CaseIterable, Identifiable {
    case viewer
    case broadcast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viewer: "Nest Camera Viewer"
        case .broadcast: "Broadcast Bridge"
        }
    }

    var systemImage: String {
        switch self {
        case .viewer: "video"
        case .broadcast: "video.badge.waveform"
        }
    }
}

enum CameraGrouping: String, CaseIterable, Identifiable {
    case home
    case room

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .room: "Room"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .room: "rectangle.3.group"
        }
    }

    func groupTitle(for camera: GoogleCamera) -> String {
        switch self {
        case .home:
            return camera.homeName
        case .room:
            if let roomName = camera.roomName, !roomName.isEmpty {
                return "\(camera.homeName) / \(roomName)"
            }
            return "\(camera.homeName) / Unassigned Room"
        }
    }
}

enum CameraFilter {
    static let allValue = "__all__"
}

struct BroadcastBridgeView: View {
    let cameras: [GoogleCamera]
    @ObservedObject var authManager: AuthManager
    @ObservedObject var controller: BroadcastBridgeController
    @AppStorage("broadcastCameraId") private var selectedCameraId = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                HStack {
                    cameraPicker

                    Button {
                        guard let camera = selectedCamera else { return }
                        controller.openWindow(camera: camera, authManager: authManager)
                    } label: {
                        Label("Open Broadcast Feed", systemImage: "rectangle.inset.filled.and.person.filled")
                    }
                    .disabled(selectedCamera == nil)
                }

                if let camera = selectedCamera {
                    CameraFeedTile(
                        camera: camera,
                        model: controller.model(for: camera),
                        authManager: authManager,
                        isZoomed: true
                    )
                    .frame(maxWidth: 960)
                } else {
                    ContentUnavailableView("No camera selected", systemImage: "video.slash")
                }
            }
            .padding()

            Spacer(minLength: 0)

            Divider()
            HStack {
                Label("OBS-ready capture window today", systemImage: "display")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Label("Native Teams/Zoom camera device requires a signed Core Media I/O Camera Extension", systemImage: "camera.badge.ellipsis")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onAppear {
            if selectedCameraId.isEmpty, let first = cameras.first {
                selectedCameraId = first.id
            }
        }
    }

    private var cameraPicker: some View {
        Picker("Camera", selection: $selectedCameraId) {
            ForEach(groupedCameras, id: \.home) { group in
                Section(group.home) {
                    ForEach(group.cameras) { camera in
                        Text(camera.roomName.map { "\($0) / \(camera.displayName)" } ?? camera.displayName)
                            .tag(camera.id)
                    }
                }
            }
        }
        .frame(minWidth: 320)
    }

    private var selectedCamera: GoogleCamera? {
        cameras.first { $0.id == selectedCameraId } ?? cameras.first
    }

    private var groupedCameras: [(home: String, cameras: [GoogleCamera])] {
        Dictionary(grouping: cameras, by: \.homeName)
            .map { home, cameras in
                (home, cameras.sorted { $0.fullDisplayName.localizedCaseInsensitiveCompare($1.fullDisplayName) == .orderedAscending })
            }
            .sorted { $0.home.localizedCaseInsensitiveCompare($1.home) == .orderedAscending }
    }
}

struct BroadcastFeedWindowView: View {
    let camera: GoogleCamera
    @ObservedObject var model: LiveFeedModel
    @ObservedObject var authManager: AuthManager

    var body: some View {
        ZStack {
            Color.black
            CameraFeedTile(
                camera: camera,
                model: model,
                authManager: authManager,
                isZoomed: false,
                showsMetadata: false
            )
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
        .onAppear {
            model.start(authManager: authManager)
        }
    }
}

struct CameraFeedTile: View {
    let camera: GoogleCamera
    @ObservedObject var model: LiveFeedModel
    let authManager: AuthManager
    let isZoomed: Bool
    var showsMetadata = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                if Constants.mockMode {
                    mockPreview
                } else if let rtspURL = model.rtspURL {
                    RTSPPlayerView(url: rtspURL)
                        .allowsHitTesting(false)
                } else if camera.supportsWebRTC {
                    WebRTCPlayerView(answerSdp: model.webRTCAnswerSdp) { offerSdp in
                        model.generateWebRTC(offerSdp: offerSdp, authManager: authManager)
                    } onStatus: { status in
                        model.status = status
                    } onError: { message in
                        model.errorMessage = message
                    }
                    .allowsHitTesting(false)
                } else {
                    unavailableView
                }

                VStack {
                    Spacer()
                    if showsMetadata {
                        metadataBar
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isZoomed, showsMetadata {
                detailStatus
                    .padding(.top, 8)
            }
        }
        .onAppear {
            model.start(authManager: authManager)
        }
    }

    private var mockPreview: some View {
        ZStack {
            LinearGradient(colors: [.black, .gray.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: camera.supportsWebRTC ? "dot.radiowaves.left.and.right" : "video.fill")
                    .font(.system(size: 48))
                Text("Mock \(camera.supportsWebRTC ? "WebRTC" : "RTSP") Preview")
                    .font(.headline)
                Text(camera.fullDisplayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.white)
        }
    }

    private var metadataBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName)
                    .font(isZoomed ? .headline : .caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(camera.locationLabel)
                    .font(.caption2)
                    .lineLimit(1)
            }

            Spacer()

            Label(camera.isOnline ? "Online" : "Offline", systemImage: camera.isOnline ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption2)
                .labelStyle(.iconOnly)
                .foregroundColor(camera.isOnline ? .green : .orange)
        }
        .foregroundColor(.white)
        .padding(8)
        .background(.black.opacity(0.58))
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.title)
            Text("No supported stream protocol")
                .font(.caption)
        }
        .foregroundColor(.white.opacity(0.75))
    }

    @ViewBuilder
    private var detailStatus: some View {
        VStack(spacing: 4) {
            Text(protocolSummary)
                .font(.caption)
                .foregroundColor(.secondary)

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
    }

    private var protocolSummary: String {
        camera.supportedProtocols.isEmpty
            ? "No stream protocols reported by SDM."
            : "Protocols: \(camera.supportedProtocols.joined(separator: ", "))"
    }
}

extension NSView {
    func snapshotImage() -> NSImage? {
        let bounds = bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }

        cacheDisplay(in: bounds, to: bitmap)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

struct WindowConfigurator: NSViewRepresentable {
    let widgetMode: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.level = widgetMode ? .floating : .normal
        window.collectionBehavior = widgetMode ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        window.titleVisibility = widgetMode ? .hidden : .visible
        window.titlebarAppearsTransparent = widgetMode

        let buttons: [NSWindow.ButtonType] = [.miniaturizeButton, .zoomButton]
        for button in buttons {
            window.standardWindowButton(button)?.isHidden = widgetMode
        }
    }
}

struct RTSPPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        view.player?.play()
        SnapshotSource.shared.view = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player = AVPlayer(url: url)
            nsView.player?.play()
        }
        SnapshotSource.shared.view = nsView
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        if SnapshotSource.shared.view === nsView {
            SnapshotSource.shared.view = nil
        }
    }
}

struct WebRTCPlayerView: NSViewRepresentable {
    let answerSdp: String?
    let onOffer: (String) -> Void
    let onStatus: (String?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffer: onOffer, onStatus: onStatus, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "native")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        SnapshotSource.shared.view = webView
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://localhost"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        SnapshotSource.shared.view = webView

        guard let answerSdp, context.coordinator.appliedAnswerSdp != answerSdp else {
            return
        }

        context.coordinator.appliedAnswerSdp = answerSdp
        context.coordinator.applyAnswer(answerSdp)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
        nsView.evaluateJavaScript("window.stopStream && window.stopStream();")
        if SnapshotSource.shared.view === nsView {
            SnapshotSource.shared.view = nil
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var appliedAnswerSdp: String?

        private let onOffer: (String) -> Void
        private let onStatus: (String?) -> Void
        private let onError: (String) -> Void

        init(onOffer: @escaping (String) -> Void, onStatus: @escaping (String?) -> Void, onError: @escaping (String) -> Void) {
            self.onOffer = onOffer
            self.onStatus = onStatus
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "offer":
                guard let sdp = body["sdp"] as? String else { return }
                onOffer(sdp)
            case "status":
                onStatus(body["message"] as? String)
            case "error":
                onError(body["message"] as? String ?? "Unknown WebRTC error.")
            default:
                break
            }
        }

        func applyAnswer(_ answerSdp: String) {
            guard let webView else { return }

            do {
                let data = try JSONSerialization.data(withJSONObject: answerSdp)
                guard let encoded = String(data: data, encoding: .utf8) else {
                    onError("Failed to encode WebRTC answer for playback.")
                    return
                }

                webView.evaluateJavaScript("window.applyAnswer(\(encoded));") { [weak self] _, error in
                    if let error {
                        self?.onError("Failed to apply WebRTC answer: \(error.localizedDescription)")
                    }
                }
            } catch {
                onError("Failed to encode WebRTC answer: \(error.localizedDescription)")
            }
        }
    }

    static let html = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body {
          background: #000;
          height: 100%;
          margin: 0;
          overflow: hidden;
        }
        video {
          background: #000;
          height: 100%;
          object-fit: contain;
          width: 100%;
        }
      </style>
    </head>
    <body>
      <video id="remoteVideo" autoplay playsinline muted></video>
      <script>
        const post = (type, payload = {}) => {
          window.webkit.messageHandlers.native.postMessage({ type, ...payload });
        };

        let pc;

        async function start() {
          try {
            if (!window.RTCPeerConnection) {
              post('error', { message: 'WKWebView does not expose RTCPeerConnection on this macOS build.' });
              return;
            }

            pc = new RTCPeerConnection({ iceServers: [] });
            pc.ontrack = event => {
              const [stream] = event.streams;
              if (stream) {
                document.getElementById('remoteVideo').srcObject = stream;
                post('status', { message: 'WebRTC stream connected.' });
              }
            };
            pc.onconnectionstatechange = () => post('status', { message: `WebRTC state: ${pc.connectionState}` });
            pc.oniceconnectionstatechange = () => post('status', { message: `ICE state: ${pc.iceConnectionState}` });

            pc.addTransceiver('audio', { direction: 'recvonly' });
            pc.addTransceiver('video', { direction: 'recvonly' });
            pc.createDataChannel('dataSendChannel');

            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            await waitForIceGatheringComplete();
            post('offer', { sdp: pc.localDescription.sdp });
          } catch (error) {
            post('error', { message: error.message || String(error) });
          }
        }

        function waitForIceGatheringComplete() {
          if (pc.iceGatheringState === 'complete') return Promise.resolve();
          return new Promise(resolve => {
            const timeout = setTimeout(resolve, 3000);
            pc.addEventListener('icegatheringstatechange', () => {
              if (pc.iceGatheringState === 'complete') {
                clearTimeout(timeout);
                resolve();
              }
            });
          });
        }

        window.applyAnswer = async answerSdp => {
          try {
            await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });
            post('status', { message: 'Waiting for media from Google...' });
          } catch (error) {
            post('error', { message: error.message || String(error) });
          }
        };

        window.stopStream = () => {
          if (pc) {
            pc.getSenders().forEach(sender => sender.track && sender.track.stop());
            pc.getReceivers().forEach(receiver => receiver.track && receiver.track.stop());
            pc.close();
          }
        };

        start();
      </script>
    </body>
    </html>
    """
}

struct KeychainHelper {
    static func saveToken(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        deleteToken(service: service, account: account)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadToken(service: String, account: String) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return data
    }

    static func deleteToken(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}

final class OAuthCallbackServer {
    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16) {
        self.port = port
    }

    func start(completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error {
                        completion(.failure(error))
                        return
                    }

                    guard let data,
                          let request = String(data: data, encoding: .utf8),
                          let code = Self.authorizationCode(from: request) else {
                        self?.sendResponse("Unable to read Google authorization code.", status: "400 Bad Request", on: connection)
                        completion(.failure(NSError(domain: Constants.appName, code: -1)))
                        return
                    }

                    self?.sendResponse("Google Home Camera Widget is connected. You can close this browser tab.", status: "200 OK", on: connection)
                    self?.listener?.cancel()
                    self?.listener = nil
                    completion(.success(code))
                }
            }
            listener.start(queue: .main)
        } catch {
            completion(.failure(error))
        }
    }

    private func sendResponse(_ body: String, status: String, on connection: NWConnection) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func authorizationCode(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first,
              let path = firstLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum IntegrationSmokeTests {
    static func run() -> Int32 {
        let cameras = MockCameraFactory.cameras()
        let streamable = CameraSelectionLogic.streamableCameras(from: cameras)

        guard streamable.count == 2 else {
            fputs("Expected 2 streamable mock cameras, got \(streamable.count)\n", stderr)
            return 1
        }

        guard streamable.allSatisfy({ $0.supportsRTSP || $0.supportsWebRTC }) else {
            fputs("Non-streamable camera leaked into streamable selection.\n", stderr)
            return 1
        }

        let selected = CameraSelectionLogic.selectedCameraId(currentId: "missing", cameras: streamable)
        guard selected == streamable[0].id else {
            fputs("Default camera selection did not choose the first streamable camera.\n", stderr)
            return 1
        }

        let preserved = CameraSelectionLogic.selectedCameraId(currentId: streamable[1].id, cameras: streamable)
        guard preserved == streamable[1].id else {
            fputs("Existing streamable selection was not preserved.\n", stderr)
            return 1
        }

        let groups = CameraSelectionLogic.groupedByHome(streamable)
        guard groups.count == 1, groups[0].cameras.count == 2 else {
            fputs("Unexpected grouped camera shape: \(groups)\n", stderr)
            return 1
        }

        print("Integration smoke tests passed.")
        return 0
    }
}

enum VideoPreviewSmokeTest {
    static func run() -> Int32 {
        let item = AVPlayerItem(url: Constants.previewTestURL)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.play()

        let deadline = Date().addingTimeInterval(20)
        var frameSize: CGSize?
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

            if item.status == .failed {
                break
            }

            let itemTime = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                frameSize = CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                break
            }
        }

        player.pause()

        if item.status == .failed {
            let message = item.error?.localizedDescription ?? "Unknown AVPlayerItem failure."
            fputs("AVPlayerItem failed: \(message)\n", stderr)
            return 1
        }

        guard let frameSize else {
            fputs("Timed out waiting for AVPlayer to decode a video frame.\n", stderr)
            return 1
        }

        print("Video preview smoke test passed. AVPlayer decoded a \(Int(frameSize.width))x\(Int(frameSize.height)) frame from the built-in HLS stream.")
        return 0
    }
}

enum CredentialedNestSmokeTest {
    static func run() -> Int32 {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        print("Credentialed Nest smoke test starting.")

        guard !OAuth2Config.deviceAccessProjectId.isEmpty else {
            fputs("Missing deviceAccessProjectId in Config/oauth2.local.json or GOOGLE_DEVICE_ACCESS_PROJECT_ID.\n", stderr)
            return 1
        }

        print("Loading Google OAuth token from Keychain...")
        guard let accessToken = validAccessToken() else {
            fputs("No usable Google OAuth token found. Open the app once and complete Sign In with Google, or provide a short-lived token with GOOGLE_ACCESS_TOKEN for this diagnostic.\n", stderr)
            return 1
        }

        print("Fetching real Google Device Access structures...")
        let structuresByName = fetchStructures(accessToken: accessToken)

        print("Fetching real Google Device Access devices...")
        let devicesResult = getJSON(path: "devices", accessToken: accessToken)
        guard case .success(let data) = devicesResult else {
            fputs("\(errorMessage(from: devicesResult))\n", stderr)
            return 1
        }

        let root: SDMDeviceResponse
        do {
            root = try JSONDecoder().decode(SDMDeviceResponse.self, from: data)
        } catch {
            fputs("Failed to parse real Device Access devices response: \(error.localizedDescription)\n", stderr)
            return 1
        }

        let cameras = root.devices
            .compactMap { camera(from: $0, structuresByName: structuresByName) }
            .sorted { $0.fullDisplayName.localizedCaseInsensitiveCompare($1.fullDisplayName) == .orderedAscending }
        let streamable = CameraSelectionLogic.streamableCameras(from: cameras)

        print("Device Access returned \(root.devices.count) real devices; \(streamable.count) are streamable cameras.")
        for camera in streamable {
            print("- \(camera.fullDisplayName) [\(camera.supportedProtocols.joined(separator: ", "))] \(camera.resourceName)")
        }

        guard !streamable.isEmpty else {
            fputs("No real streamable cameras were returned by Device Access.\n", stderr)
            return 1
        }

        let requestedCameraId = argumentValue(after: "--camera-id") ?? ProcessInfo.processInfo.environment["NEST_CAMERA_SMOKE_CAMERA_ID"]
        let selectedCamera = requestedCameraId.flatMap { id in streamable.first { $0.id == id || $0.resourceName == id } }
            ?? streamable.first { $0.supportsRTSP }
            ?? streamable[0]

        print("Selected real camera: \(selectedCamera.fullDisplayName)")

        if selectedCamera.supportsRTSP {
            return runRTSPSmoke(camera: selectedCamera, accessToken: accessToken)
        }

        if selectedCamera.supportsWebRTC {
            return runWebRTCSmoke(camera: selectedCamera, accessToken: accessToken)
        }

        fputs("Selected camera does not report RTSP or WebRTC support.\n", stderr)
        return 1
    }

    fileprivate static func executeStreamCommand(
        camera: GoogleCamera,
        command: String,
        params: [String: Any],
        accessToken: String
    ) -> Result<Data, Error> {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/\(camera.resourceName):executeCommand"
        guard let url = URL(string: urlString) else {
            return .failure(NSError(domain: Constants.appName, code: -90, userInfo: [NSLocalizedDescriptionKey: "Invalid stream command URL."]))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "params": params])
        } catch {
            return .failure(error)
        }

        return send(request: request)
    }

    private static func runRTSPSmoke(camera: GoogleCamera, accessToken: String) -> Int32 {
        print("Requesting real RTSP stream from Google...")
        let result = executeStreamCommand(
            camera: camera,
            command: "sdm.devices.commands.CameraLiveStream.GenerateRtspStream",
            params: [:],
            accessToken: accessToken
        )

        guard case .success(let data) = result else {
            fputs("\(errorMessage(from: result))\n", stderr)
            return 1
        }

        do {
            let response = try JSONDecoder().decode(GenerateRTSPStreamResponse.self, from: data)
            guard let urlString = response.results.streamUrls?["rtspUrl"], let url = URL(string: urlString) else {
                fputs("Google RTSP command succeeded but did not return results.streamUrls.rtspUrl.\n", stderr)
                return 1
            }

            print("Google returned RTSP URL; attempting to decode a real video frame...")
            return decodeFrame(from: url, label: "real Google RTSP stream")
        } catch {
            fputs("Failed to parse Google RTSP response: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runWebRTCSmoke(camera: GoogleCamera, accessToken: String) -> Int32 {
        print("Requesting real WebRTC stream from Google...")

        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var result: Int32 = 1
            var session: CredentialedWebRTCSmokeSession?
        }
        let box = Box()

        let start = {
            box.session = CredentialedWebRTCSmokeSession(camera: camera, accessToken: accessToken) { result in
                box.result = result
                semaphore.signal()
            }
            box.session?.start()
        }

        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }

        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success {
                box.session?.stop()
                return box.result
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        box.session?.stop()
        fputs("Timed out waiting for real Google WebRTC video media.\n", stderr)
        return 1
    }

    private static func decodeFrame(from url: URL, label: String) -> Int32 {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.play()

        let deadline = Date().addingTimeInterval(25)
        var frameSize: CGSize?
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

            if item.status == .failed {
                break
            }

            let itemTime = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
                break
            }
        }

        player.pause()

        if item.status == .failed {
            let message = item.error?.localizedDescription ?? "Unknown AVPlayerItem failure."
            fputs("AVPlayer failed for \(label): \(message)\n", stderr)
            return 1
        }

        guard let frameSize else {
            fputs("Timed out waiting for AVPlayer to decode a frame from \(label).\n", stderr)
            return 1
        }

        print("Credentialed Nest smoke test passed. Decoded \(Int(frameSize.width))x\(Int(frameSize.height)) from \(label).")
        return 0
    }

    private static func validAccessToken() -> String? {
        if let token = ProcessInfo.processInfo.environment["GOOGLE_ACCESS_TOKEN"], !token.isEmpty {
            print("Using GOOGLE_ACCESS_TOKEN from environment for credentialed smoke test.")
            return token
        }

        guard let data = loadStoredToken(timeout: 8),
              var token = try? JSONDecoder().decode(AuthToken.self, from: data) else {
            return nil
        }

        if token.isAboutToExpire() {
            print("Stored token is near expiry; refreshing token...")
            guard let refreshed = refresh(token: token) else {
                return nil
            }
            token = refreshed
        }

        return token.accessToken
    }

    private static func loadStoredToken(timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var data: Data?
        }
        let box = Box()

        DispatchQueue.global(qos: .userInitiated).async {
            print("Reading token from Keychain...")
            box.data = KeychainHelper.loadToken(service: Constants.appName, account: "auth_token")
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            fputs("Timed out reading Google OAuth token from Keychain. The installed app may have Keychain access that this diagnostic process cannot use.\n", stderr)
            return nil
        }

        return box.data
    }

    private static func refresh(token: AuthToken) -> AuthToken? {
        guard let refreshToken = token.refreshToken, let url = URL(string: Constants.tokenEndpoint) else {
            return nil
        }

        var params = [
            "client_id": OAuth2Config.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = OAuth2Config.clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(from: params)

        let result = send(request: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard case .success(let data) = result,
              let response = try? decoder.decode(TokenResponse.self, from: data) else {
            return nil
        }

        let newToken = AuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? token.refreshToken,
            expiresInSeconds: response.expiresIn,
            issuedAt: Date()
        )

        if let encoded = try? JSONEncoder().encode(newToken) {
            KeychainHelper.saveToken(encoded, service: Constants.appName, account: "auth_token")
        }

        return newToken
    }

    private static func fetchStructures(accessToken: String) -> [String: String] {
        guard case .success(let data) = getJSON(path: "structures", accessToken: accessToken),
              let root = try? JSONDecoder().decode(SDMStructureResponse.self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: root.structures.map { structure in
            (structure.name, structureDisplayName(from: structure))
        })
    }

    private static func getJSON(path: String, accessToken: String) -> Result<Data, Error> {
        guard let url = URL(string: "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(OAuth2Config.deviceAccessProjectId)/\(path)") else {
            return .failure(NSError(domain: Constants.appName, code: -91, userInfo: [NSLocalizedDescriptionKey: "Invalid Device Access URL."]))
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return send(request: request)
    }

    private static func send(request: URLRequest) -> Result<Data, Error> {
        var request = request
        request.timeoutInterval = 20

        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var result: Result<Data, Error> = .failure(NSError(domain: Constants.appName, code: -92))
        }
        let box = Box()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                box.result = .failure(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, let data else {
                box.result = .failure(NSError(domain: Constants.appName, code: -93, userInfo: [NSLocalizedDescriptionKey: "No HTTP response."]))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "No response body."
                box.result = .failure(NSError(domain: Constants.appName, code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]))
                return
            }

            box.result = .success(data)
        }
        task.resume()

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success {
                return box.result
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        task.cancel()
        return .failure(NSError(domain: Constants.appName, code: -94, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for HTTP response from \(request.url?.absoluteString ?? "unknown URL")."]))
    }

    private static func camera(from device: SDMDevice, structuresByName: [String: String]) -> GoogleCamera? {
        guard let traits = device.traits,
              let streamTrait = traits[Constants.cameraLiveStreamTrait] else {
            return nil
        }

        let protocols = streamTrait["supportedProtocols"]?.stringArray ?? []
        let infoTrait = traits[Constants.infoTrait]
        let deviceTrait = traits[Constants.deviceTrait]
        let customName = infoTrait?["customName"]?.stringValue
        let relation = device.parentRelations?.first
        let structureResourceName = structureResourceName(from: relation?.parent)
        let relationIsRoom = relation?.parent?.contains("/rooms/") == true
        let roomName = relationIsRoom ? relation?.displayName : nil
        let homeName = structureResourceName.flatMap { structuresByName[$0] }
            ?? (!relationIsRoom ? relation?.displayName : nil)
            ?? fallbackHomeName(from: structureResourceName)
        let online = deviceTrait?["connectivity"]?["status"]?.stringValue == "ONLINE"

        return GoogleCamera(
            id: device.name,
            resourceName: device.name,
            displayName: customName ?? roomName ?? device.name.components(separatedBy: "/").last ?? "Camera",
            homeName: homeName,
            roomName: roomName,
            brandName: "Google Nest",
            supportedProtocols: protocols,
            isOnline: online
        )
    }

    private static func formBody(from params: [String: String]) -> Data? {
        params
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func structureDisplayName(from structure: SDMStructure) -> String {
        structure.traits?[Constants.structureInfoTrait]?["customName"]?.stringValue
            ?? structure.parentRelations?.first?.displayName
            ?? fallbackHomeName(from: structure.name)
    }

    private static func structureResourceName(from parent: String?) -> String? {
        guard let parent,
              let range = parent.range(of: #"/structures/[^/]+"#, options: .regularExpression) else {
            return nil
        }

        return String(parent[..<range.upperBound])
    }

    private static func fallbackHomeName(from structureResourceName: String?) -> String {
        guard let structureResourceName,
              let suffix = structureResourceName.components(separatedBy: "/").last,
              !suffix.isEmpty else {
            return "Unknown Home"
        }
        return "Home \(suffix)"
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }

    private static func errorMessage(from result: Result<Data, Error>) -> String {
        guard case .failure(let error) = result else { return "" }
        return error.localizedDescription
    }
}

final class CredentialedWebRTCSmokeSession: NSObject, WKScriptMessageHandler {
    private let camera: GoogleCamera
    private let accessToken: String
    private let completion: (Int32) -> Void
    private let webView: WKWebView
    private var completed = false

    init(camera: GoogleCamera, accessToken: String, completion: @escaping (Int32) -> Void) {
        self.camera = camera
        self.accessToken = accessToken
        self.completion = completion

        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)

        super.init()
        contentController.add(self, name: "native")
    }

    func start() {
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://localhost"))
    }

    func stop() {
        webView.evaluateJavaScript("window.stopStream && window.stopStream();")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "offer":
            guard let sdp = body["sdp"] as? String else { return }
            requestAnswer(offerSdp: sdp)
        case "status":
            if let message = body["message"] as? String {
                print("WebRTC: \(message)")
            }
        case "frame":
            let width = body["width"] as? Int ?? 0
            let height = body["height"] as? Int ?? 0
            print("Credentialed Nest smoke test passed. WebRTC video element received a \(width)x\(height) frame from \(camera.fullDisplayName).")
            finish(0)
        case "error":
            let message = body["message"] as? String ?? "Unknown WebRTC error."
            fputs("WebRTC smoke test failed: \(message)\n", stderr)
            finish(1)
        default:
            break
        }
    }

    private func requestAnswer(offerSdp: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CredentialedNestSmokeTest.executeStreamCommand(
                camera: self.camera,
                command: "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream",
                params: ["offerSdp": offerSdp],
                accessToken: self.accessToken
            )

            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        let response = try JSONDecoder().decode(GenerateWebRTCStreamResponse.self, from: data)
                        self.apply(answerSdp: response.results.answerSdp)
                    } catch {
                        fputs("Failed to parse Google WebRTC response: \(error.localizedDescription)\n", stderr)
                        self.finish(1)
                    }
                case .failure(let error):
                    fputs("Google WebRTC command failed: \(error.localizedDescription)\n", stderr)
                    self.finish(1)
                }
            }
        }
    }

    private func apply(answerSdp: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: answerSdp)
            guard let encoded = String(data: data, encoding: .utf8) else {
                fputs("Failed to encode Google WebRTC answer for JavaScript.\n", stderr)
                finish(1)
                return
            }
            webView.evaluateJavaScript("window.applyAnswer(\(encoded));")
        } catch {
            fputs("Failed to encode Google WebRTC answer: \(error.localizedDescription)\n", stderr)
            finish(1)
        }
    }

    private func finish(_ result: Int32) {
        guard !completed else { return }
        completed = true
        completion(result)
    }

    private static let html = """
    <!doctype html>
    <html>
    <body>
      <video id="remoteVideo" autoplay playsinline muted></video>
      <script>
        const post = (type, payload = {}) => window.webkit.messageHandlers.native.postMessage({ type, ...payload });
        const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
        let pc;

        async function start() {
          try {
            if (!window.RTCPeerConnection) {
              post('error', { message: 'WKWebView does not expose RTCPeerConnection on this macOS build.' });
              return;
            }

            pc = new RTCPeerConnection({ iceServers: [] });
            pc.ontrack = event => {
              const [stream] = event.streams;
              if (stream) {
                const video = document.getElementById('remoteVideo');
                video.srcObject = stream;
                post('status', { message: 'Remote track received.' });
                waitForFrame(video);
              }
            };
            pc.onconnectionstatechange = () => post('status', { message: `connectionState=${pc.connectionState}` });
            pc.oniceconnectionstatechange = () => post('status', { message: `iceConnectionState=${pc.iceConnectionState}` });

            pc.addTransceiver('audio', { direction: 'recvonly' });
            pc.addTransceiver('video', { direction: 'recvonly' });
            pc.createDataChannel('dataSendChannel');

            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            await waitForIceGatheringComplete();
            post('offer', { sdp: pc.localDescription.sdp });
          } catch (error) {
            post('error', { message: error.message || String(error) });
          }
        }

        async function waitForFrame(video) {
          const deadline = Date.now() + 25000;
          while (Date.now() < deadline) {
            if (video.videoWidth > 0 && video.videoHeight > 0 && video.readyState >= 2) {
              post('frame', { width: video.videoWidth, height: video.videoHeight });
              return;
            }
            await sleep(100);
          }
          post('error', { message: `Timed out waiting for a decoded WebRTC video frame. readyState=${video.readyState}, size=${video.videoWidth}x${video.videoHeight}` });
        }

        function waitForIceGatheringComplete() {
          if (pc.iceGatheringState === 'complete') return Promise.resolve();
          return new Promise(resolve => {
            const timeout = setTimeout(resolve, 3000);
            pc.addEventListener('icegatheringstatechange', () => {
              if (pc.iceGatheringState === 'complete') {
                clearTimeout(timeout);
                resolve();
              }
            });
          });
        }

        window.applyAnswer = async answerSdp => {
          try {
            await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });
            post('status', { message: 'Google WebRTC answer applied.' });
          } catch (error) {
            post('error', { message: error.message || String(error) });
          }
        };

        window.stopStream = () => {
          if (pc) {
            pc.getSenders().forEach(sender => sender.track && sender.track.stop());
            pc.getReceivers().forEach(receiver => receiver.track && receiver.track.stop());
            pc.close();
          }
        };

        start();
      </script>
    </body>
    </html>
    """
}

@main
struct GoogleHomeCameraWidgetApp: App {
    private static let isCredentialedSmokeTest = CommandLine.arguments.contains("--nest-camera-smoke-test")

    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            exit(IntegrationSmokeTests.run())
        }
        if CommandLine.arguments.contains("--video-smoke-test") {
            exit(VideoPreviewSmokeTest.run())
        }
        if Self.isCredentialedSmokeTest {
            DispatchQueue.main.async {
                exit(CredentialedNestSmokeTest.run())
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isCredentialedSmokeTest {
                EmptyView()
            } else {
                CameraView()
            }
        }
    }
}
