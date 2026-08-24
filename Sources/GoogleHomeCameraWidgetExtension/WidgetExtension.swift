import AppIntents
import CryptoKit
import Darwin
import ImageIO
import OSLog
import SwiftUI
import WidgetKit

enum SnapshotStore {
    private static let logger = Logger(subsystem: "com.jeffalderson.google-home-camera-widget.snapshot-widget", category: "SnapshotStore")

    // Widget extensions get a containerized Foundation home directory. The app
    // deliberately publishes snapshots in the signed-in user's real home.
    static var userHomeDirectory: URL {
        guard let passwordEntry = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: passwordEntry.pointee.pw_dir), isDirectory: true)
    }

    static var directory: URL {
        userHomeDirectory
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

    static func catalog() -> [CameraCatalogEntry] {
        do {
            let data = try Data(contentsOf: catalogURL)
            let catalog = try JSONDecoder().decode([CameraCatalogEntry].self, from: data)
            logger.info("Loaded \(catalog.count, privacy: .public) cameras from the shared catalog")
            return catalog.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            logger.error("Unable to load camera catalog at \(catalogURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func viewerURL(cameraId: String?) -> URL? {
        guard let cameraId else { return nil }
        var components = URLComponents()
        components.scheme = "googlehomecamerawidget"
        components.host = "camera"
        components.queryItems = [URLQueryItem(name: "id", value: cameraId)]
        return components.url
    }

    static func load(cameraId: String?) -> CameraSnapshot {
        let catalog = catalog()
        guard let cameraId,
              let camera = catalog.first(where: { $0.id == cameraId }) else {
            return CameraSnapshot(image: nil, cameraName: "Choose a camera", homeName: nil, roomName: nil, updatedAt: nil)
        }

        let image = loadImage(cameraId: camera.id)
        let metadata = try? JSONDecoder().decode(SnapshotMetadata.self, from: Data(contentsOf: metadataURL(for: camera.id)))

        return CameraSnapshot(
            image: image,
            cameraName: metadata?.cameraName ?? camera.cameraName,
            homeName: metadata?.homeName ?? camera.homeName,
            roomName: metadata?.roomName ?? camera.roomName,
            updatedAt: metadata?.updatedAt
        )
    }

    private static func loadImage(cameraId: String) -> CGImage? {
        let url = imageURL(for: cameraId)
        do {
            let data = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                logger.error("Unable to decode camera snapshot at \(url.path, privacy: .public)")
                return nil
            }
            logger.info("Loaded camera snapshot \(image.width, privacy: .public)x\(image.height, privacy: .public)")
            return image
        } catch {
            logger.error("Unable to read camera snapshot at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

struct SnapshotMetadata: Decodable {
    let cameraId: String
    let cameraName: String
    let homeName: String
    let roomName: String?
    let updatedAt: Date
}

struct CameraSnapshot {
    let image: CGImage?
    let cameraName: String
    let homeName: String?
    let roomName: String?
    let updatedAt: Date?

    var locationLabel: String? {
        guard let homeName else { return nil }
        if let roomName, !roomName.isEmpty {
            return "\(homeName) / \(roomName)"
        }
        return homeName
    }
}

struct CameraSelectionEntity: AppEntity {
    static let persistentIdentifier = "CameraSelectionEntity"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Camera")
    static let defaultQuery = CameraSelectionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct CameraSelectionQuery: EntityQuery {
    func entities(for identifiers: [CameraSelectionEntity.ID]) async throws -> [CameraSelectionEntity] {
        SnapshotStore.catalog()
            .filter { identifiers.contains($0.id) }
            .map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }

    func suggestedEntities() async throws -> [CameraSelectionEntity] {
        SnapshotStore.catalog().map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }

    func defaultResult() async -> CameraSelectionEntity? {
        nil
    }
}

struct CameraSnapshotConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Nest Camera"
    static var description = IntentDescription("Choose which Google Nest camera this widget displays.")

    @Parameter(title: "Camera")
    var camera: CameraSelectionEntity?

    init() {
        camera = nil
    }

    init(camera: CameraSelectionEntity?) {
        self.camera = camera
    }
}

struct CameraSnapshotEntry: TimelineEntry {
    let date: Date
    let configuration: CameraSnapshotConfiguration
    let snapshot: CameraSnapshot
}

struct CameraSnapshotProvider: AppIntentTimelineProvider {
    static func entry(for configuration: CameraSnapshotConfiguration, date: Date = Date()) -> CameraSnapshotEntry {
        CameraSnapshotEntry(
            date: date,
            configuration: configuration,
            snapshot: SnapshotStore.load(cameraId: configuration.camera?.id)
        )
    }

    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(
            date: Date(),
            configuration: CameraSnapshotConfiguration(),
            snapshot: CameraSnapshot(image: nil, cameraName: "Choose a camera", homeName: nil, roomName: nil, updatedAt: nil)
        )
    }

    func snapshot(for configuration: CameraSnapshotConfiguration, in context: Context) async -> CameraSnapshotEntry {
        Self.entry(for: configuration)
    }

    func timeline(for configuration: CameraSnapshotConfiguration, in context: Context) async -> Timeline<CameraSnapshotEntry> {
        let now = Date()
        let entry = Self.entry(for: configuration, date: now)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60)))
    }
}

struct CameraSnapshotWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            if let image = entry.snapshot.image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title)
                    Text(emptyMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.white.opacity(0.8))
                .padding()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.cameraName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let location = entry.snapshot.locationLabel {
                    Text(location)
                        .font(.caption2)
                        .lineLimit(1)
                }

                if let updatedAt = entry.snapshot.updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.caption2)
                } else {
                    Text("Waiting for snapshot")
                        .font(.caption2)
                }
            }
            .foregroundColor(.white)
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
        .containerBackground(.black, for: .widget)
        .widgetURL(SnapshotStore.viewerURL(cameraId: entry.configuration.camera?.id))
    }

    private var emptyMessage: String {
        if SnapshotStore.catalog().isEmpty {
            return "Open the camera viewer and load cameras."
        }
        if entry.configuration.camera == nil {
            return "Right-click and choose Edit Widget to select a camera."
        }
        return "Waiting for the next camera snapshot. Keep the camera app open."
    }
}

private struct GoogleHomeCameraSnapshotWidget: Widget {
    let kind = "GoogleHomeCameraSnapshotWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CameraSnapshotConfiguration.self, provider: CameraSnapshotProvider()) { entry in
            CameraSnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName("Nest Camera Snapshot")
        .description("Choose one discovered Nest camera per widget and show its latest captured frame.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#if !WIDGET_E2E_TEST
@main
private struct GoogleHomeCameraWidgetBundle: WidgetBundle {
    var body: some Widget {
        GoogleHomeCameraSnapshotWidget()
    }
}
#endif
