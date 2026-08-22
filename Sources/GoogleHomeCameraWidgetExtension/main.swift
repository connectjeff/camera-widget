import AppIntents
import CryptoKit
import SwiftUI
import WidgetKit

private enum SnapshotStore {
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

    static func catalog() -> [CameraCatalogEntry] {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode([CameraCatalogEntry].self, from: data) else {
            return []
        }
        return catalog.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func load(cameraId: String?) -> CameraSnapshot {
        let catalog = catalog()
        let camera = cameraId.flatMap { id in catalog.first(where: { $0.id == id }) } ?? catalog.first

        guard let camera else {
            return CameraSnapshot(image: nil, cameraName: "Google Nest Camera", homeName: nil, roomName: nil, updatedAt: nil)
        }

        let image = NSImage(contentsOf: imageURL(for: camera.id))
        let metadata = try? JSONDecoder().decode(SnapshotMetadata.self, from: Data(contentsOf: metadataURL(for: camera.id)))

        return CameraSnapshot(
            image: image,
            cameraName: metadata?.cameraName ?? camera.cameraName,
            homeName: metadata?.homeName ?? camera.homeName,
            roomName: metadata?.roomName ?? camera.roomName,
            updatedAt: metadata?.updatedAt
        )
    }

    private static func fileToken(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CameraCatalogEntry: Codable, Identifiable, Hashable {
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

private struct SnapshotMetadata: Decodable {
    let cameraId: String
    let cameraName: String
    let homeName: String
    let roomName: String?
    let updatedAt: Date
}

private struct CameraSnapshot {
    let image: NSImage?
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

private struct CameraSelectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Camera")
    static let defaultQuery = CameraSelectionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

private struct CameraSelectionQuery: EntityQuery {
    func entities(for identifiers: [CameraSelectionEntity.ID]) async throws -> [CameraSelectionEntity] {
        SnapshotStore.catalog()
            .filter { identifiers.contains($0.id) }
            .map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }

    func suggestedEntities() async throws -> [CameraSelectionEntity] {
        SnapshotStore.catalog().map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }

    func defaultResult() async -> CameraSelectionEntity? {
        SnapshotStore.catalog().first.map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }
}

private struct CameraSnapshotConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Nest Camera"
    static var description = IntentDescription("Choose which Google Nest camera this widget displays.")

    @Parameter(title: "Camera")
    var camera: CameraSelectionEntity?
}

private struct CameraSnapshotEntry: TimelineEntry {
    let date: Date
    let configuration: CameraSnapshotConfiguration
    let snapshot: CameraSnapshot
}

private struct CameraSnapshotProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(
            date: Date(),
            configuration: CameraSnapshotConfiguration(),
            snapshot: CameraSnapshot(image: nil, cameraName: "Google Nest Camera", homeName: nil, roomName: nil, updatedAt: nil)
        )
    }

    func snapshot(for configuration: CameraSnapshotConfiguration, in context: Context) async -> CameraSnapshotEntry {
        CameraSnapshotEntry(date: Date(), configuration: configuration, snapshot: SnapshotStore.load(cameraId: configuration.camera?.id))
    }

    func timeline(for configuration: CameraSnapshotConfiguration, in context: Context) async -> Timeline<CameraSnapshotEntry> {
        let now = Date()
        let entry = CameraSnapshotEntry(date: now, configuration: configuration, snapshot: SnapshotStore.load(cameraId: configuration.camera?.id))
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60)))
    }
}

private struct CameraSnapshotWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            if let image = entry.snapshot.image {
                Image(nsImage: image)
                    .resizable()
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
    }

    private var emptyMessage: String {
        if SnapshotStore.catalog().isEmpty {
            return "Open the camera viewer and load cameras."
        }
        return "Open the selected camera in the viewer to create a snapshot."
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

@main
private struct GoogleHomeCameraWidgetBundle: WidgetBundle {
    var body: some Widget {
        GoogleHomeCameraSnapshotWidget()
    }
}
