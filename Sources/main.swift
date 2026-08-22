import AVKit
import CryptoKit
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
}

struct AppConfig: Decodable {
    let clientId: String?
    let clientSecret: String?
    let deviceAccessProjectId: String?

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

        return AppConfig(clientId: nil, clientSecret: nil, deviceAccessProjectId: nil)
    }
}

struct OAuth2Config {
    static let fileConfig = AppConfig.load()

    static let clientId = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"] ?? fileConfig.clientId ?? ""
    static let clientSecret = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"] ?? fileConfig.clientSecret
    static let deviceAccessProjectId = ProcessInfo.processInfo.environment["GOOGLE_DEVICE_ACCESS_PROJECT_ID"] ?? fileConfig.deviceAccessProjectId ?? ""

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
        loadToken()
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

        let verifier = Self.makeCodeVerifier()
        codeVerifier = verifier

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
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: Constants.redirectURI),
            URLQueryItem(name: "client_id", value: OAuth2Config.clientId),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.sdmScope),
            URLQueryItem(name: "code_challenge", value: Self.makeCodeChallenge(from: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

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
            "redirect_uri": Constants.redirectURI,
            "code_verifier": codeVerifier ?? ""
        ]

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

struct SDMDeviceResponse: Decodable {
    let devices: [SDMDevice]
}

struct SDMStructureResponse: Decodable {
    let structures: [SDMStructure]
}

struct SDMDevice: Decodable {
    let name: String
    let type: String?
    let traits: [String: JSONValue]?
    let parentRelations: [ParentRelation]?
}

struct ParentRelation: Decodable {
    let parent: String?
    let displayName: String?
}

struct SDMStructure: Decodable {
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

enum JSONValue: Decodable {
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

    @AppStorage("selectedCameraId") private var storedSelection: String?

    func loadCameras(authManager: AuthManager) {
        isLoading = true
        errorMessage = nil
        rtspURL = nil
        webRTCAnswerSdp = nil
        webRTCStatus = nil

        guard !OAuth2Config.deviceAccessProjectId.isEmpty else {
            isLoading = false
            errorMessage = "Configure your Google Device Access project ID before loading cameras."
            return
        }

        authManager.validAccessToken { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let accessToken):
                    self?.fetchCameras(with: accessToken)
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

    private func fetchCameras(with accessToken: String) {
        fetchStructures(with: accessToken) { [weak self] structuresByName in
            Task { @MainActor in
                self?.fetchDevices(with: accessToken, structuresByName: structuresByName)
            }
        }
    }

    private func fetchStructures(with accessToken: String, completion: @escaping ([String: String]) -> Void) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(OAuth2Config.deviceAccessProjectId)/structures"
        guard let url = URL(string: urlString) else {
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

    private func fetchDevices(with accessToken: String, structuresByName: [String: String]) {
        let urlString = "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(OAuth2Config.deviceAccessProjectId)/devices"
        guard let url = URL(string: urlString) else {
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
    @AppStorage("widgetMode") private var widgetMode = false
    @State private var snapshotTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if authManager.isLoading || cameraManager.isLoading {
                loadingView
            } else if !authManager.isAuthenticated {
                authenticationView
            } else if cameraManager.cameras.isEmpty {
                emptyCameraView
            } else if let camera = cameraManager.selectedCamera {
                cameraDetailView(for: camera)
            }
        }
        .frame(minWidth: widgetMode ? 380 : 620, minHeight: widgetMode ? 300 : 420)
        .background(WindowConfigurator(widgetMode: widgetMode))
        .onAppear {
            if authManager.isAuthenticated {
                cameraManager.loadCameras(authManager: authManager)
            }
            startSnapshotTimer()
        }
        .onDisappear {
            snapshotTimer?.invalidate()
            snapshotTimer = nil
        }
    }

    private var header: some View {
        HStack {
            Label("Nest Camera Tester", systemImage: "video")
                .font(.headline)
            Spacer()
            if authManager.isAuthenticated {
                Toggle(isOn: $widgetMode) {
                    Label("Widget Mode", systemImage: widgetMode ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)

                Button {
                    cameraManager.loadCameras(authManager: authManager)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    authManager.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
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

            Button {
                authManager.authorize()
            } label: {
                Label("Sign In with Google", systemImage: "person.crop.circle.badge.checkmark")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCameraView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No authorized cameras found")
                .font(.title3)
                .fontWeight(.semibold)
            errorText
            Button {
                cameraManager.loadCameras(authManager: authManager)
            } label: {
                Label("Load Cameras", systemImage: "arrow.clockwise")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cameraDetailView(for camera: GoogleCamera) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Camera", selection: Binding(
                    get: { cameraManager.selectedCamera },
                    set: { newValue in
                        if let newValue {
                            cameraManager.selectCamera(newValue)
                        }
                    }
                )) {
                    ForEach(cameraManager.cameras) { camera in
                        Text(camera.fullDisplayName).tag(camera as GoogleCamera?)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Label(camera.isOnline ? "Online" : "Offline", systemImage: camera.isOnline ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundColor(camera.isOnline ? .green : .orange)
            }
            .padding()

            VStack(spacing: 16) {
                ZStack {
                    Color.black
                    if let rtspURL = cameraManager.rtspURL {
                        RTSPPlayerView(url: rtspURL)
                    } else if camera.supportsWebRTC {
                        WebRTCPlayerView(answerSdp: cameraManager.webRTCAnswerSdp) { offerSdp in
                            cameraManager.generateWebRTCStream(authManager: authManager, offerSdp: offerSdp)
                        } onStatus: { status in
                            cameraManager.webRTCStatus = status
                        } onError: { message in
                            cameraManager.errorMessage = message
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "video")
                                .font(.system(size: 52))
                            Text(camera.displayName)
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text(camera.locationLabel)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text(protocolSummary(for: camera))
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.white)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let expiresAt = cameraManager.streamExpiresAt {
                    Text("Stream token expires at \(expiresAt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let status = cameraManager.webRTCStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                errorText

                HStack {
                    if camera.supportsRTSP {
                        Button {
                            cameraManager.generateRTSPStream(authManager: authManager)
                        } label: {
                            Label("Start RTSP Stream", systemImage: "play.fill")
                        }
                    }

                    if camera.supportsWebRTC {
                        Label("WebRTC starts automatically", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
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

    private func startSnapshotTimer() {
        guard snapshotTimer == nil else { return }

        captureSnapshotForWidget()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                captureSnapshotForWidget()
            }
        }
    }

    private func captureSnapshotForWidget() {
        guard authManager.isAuthenticated,
              let camera = cameraManager.selectedCamera,
              let image = SnapshotSource.shared.view?.snapshotImage() ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?.snapshotImage() else {
            return
        }

        do {
            try SnapshotStore.write(image: image, camera: camera)
            cameraManager.webRTCStatus = "Widget snapshot updated at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            cameraManager.errorMessage = "Failed to write widget snapshot: \(error.localizedDescription)"
        }
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

    private static let html = """
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
      <video id="remoteVideo" autoplay playsinline controls muted></video>
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
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

@main
struct GoogleHomeCameraWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
        }
    }
}
