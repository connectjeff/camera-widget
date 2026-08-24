import AppIntents
import Foundation

private enum HostWidgetCameraCatalog {
    static var catalogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GoogleHomeCameraWidget", isDirectory: true)
            .appendingPathComponent("camera-catalog.json")
    }

    static func entries() -> [CameraCatalogEntry] {
        guard let data = try? Data(contentsOf: catalogURL),
              let entries = try? JSONDecoder().decode([CameraCatalogEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

struct CameraSelectionEntity: AppEntity {
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
        HostWidgetCameraCatalog.entries()
            .filter { identifiers.contains($0.id) }
            .map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
    }

    func suggestedEntities() async throws -> [CameraSelectionEntity] {
        HostWidgetCameraCatalog.entries().map { CameraSelectionEntity(id: $0.id, title: $0.displayName) }
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
}
