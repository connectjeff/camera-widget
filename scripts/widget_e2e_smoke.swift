import AppIntents
import AppKit
import SwiftUI
import WidgetKit

enum WidgetSmokeFailure: Error, CustomStringConvertible {
    case noCameras
    case noSnapshot
    case entityRoundTrip
    case timelineEntry
    case render
    case uniformRender

    var description: String {
        switch self {
        case .noCameras: return "The real camera catalog is empty"
        case .noSnapshot: return "No catalog camera has a readable snapshot"
        case .entityRoundTrip: return "The selected AppEntity identifier did not resolve"
        case .timelineEntry: return "The timeline entry did not contain the selected camera frame"
        case .render: return "The actual widget view could not be rendered"
        case .uniformRender: return "The actual widget view collapsed to a uniform field"
        }
    }
}

@main
struct WidgetEndToEndSmoke {
    @MainActor
    static func main() async throws {
        let query = CameraSelectionQuery()
        let cameras = try await query.suggestedEntities()
        guard !cameras.isEmpty else { throw WidgetSmokeFailure.noCameras }

        guard let selected = cameras.first(where: { SnapshotStore.load(cameraId: $0.id).image != nil }) else {
            throw WidgetSmokeFailure.noSnapshot
        }
        let resolved = try await query.entities(for: [selected.id])
        guard resolved.count == 1, resolved[0].id == selected.id else {
            throw WidgetSmokeFailure.entityRoundTrip
        }

        let configuration = CameraSnapshotConfiguration(camera: resolved[0])
        let entry = CameraSnapshotProvider.entry(for: configuration)
        guard entry.configuration.camera?.id == selected.id, entry.snapshot.image != nil else {
            throw WidgetSmokeFailure.timelineEntry
        }

        let content = CameraSnapshotWidgetView(entry: entry)
            .frame(width: 344, height: 164)
            .environment(\.widgetRenderingMode, .accented)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw WidgetSmokeFailure.render
        }

        var minimumLuminance = 1.0
        var maximumLuminance = 0.0
        var minimumAlpha = 1.0
        var maximumAlpha = 0.0
        // Inspect only the upper image region so text and metadata cannot make a
        // missing camera frame look like a successful render.
        for y in stride(from: 0, to: bitmap.pixelsHigh * 2 / 3, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                minimumLuminance = min(minimumLuminance, luminance)
                maximumLuminance = max(maximumLuminance, luminance)
                minimumAlpha = min(minimumAlpha, color.alphaComponent)
                maximumAlpha = max(maximumAlpha, color.alphaComponent)
            }
        }
        guard maximumLuminance - minimumLuminance > 0.2 || maximumAlpha - minimumAlpha > 0.2 else {
            throw WidgetSmokeFailure.uniformRender
        }

        let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/widget-e2e-smoke.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WidgetSmokeFailure.render
        }
        try png.write(to: outputURL, options: .atomic)

        let entityIdentifier = EntityIdentifier(for: resolved[0])
        print("Widget E2E passed")
        print("Camera: \(resolved[0].title)")
        print("Entity: \(entityIdentifier)")
        print("Frame: \(entry.snapshot.image!.width)x\(entry.snapshot.image!.height)")
        print("Rendered: \(outputURL.path)")
    }
}
