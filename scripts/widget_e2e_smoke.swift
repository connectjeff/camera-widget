import AppKit
import SwiftUI
import WidgetKit

enum WidgetSmokeFailure: Error, CustomStringConvertible {
    case noCameras
    case noSnapshot
    case optionsProvider
    case timelineEntry
    case render
    case uniformRender

    var description: String {
        switch self {
        case .noCameras: return "The real camera catalog is empty"
        case .noSnapshot: return "No catalog camera has a readable snapshot"
        case .optionsProvider: return "The camera options provider did not return the selected camera ID"
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
        let catalog = SnapshotStore.catalog()
        guard !catalog.isEmpty else { throw WidgetSmokeFailure.noCameras }

        guard let selected = catalog.first(where: { SnapshotStore.load(cameraId: $0.id).image != nil }) else {
            throw WidgetSmokeFailure.noSnapshot
        }
        let options = try await CameraOptionsProvider().results()
        let optionItems = options.sections.flatMap(\.items)
        guard let selectedOption = optionItems.first(where: { $0.value == selected.id }),
              !String(localized: selectedOption.description.title).isEmpty else {
            throw WidgetSmokeFailure.optionsProvider
        }

        let configuration = CameraSnapshotConfiguration(cameraId: selected.id)
        let entry = CameraSnapshotProvider.entry(for: configuration)
        guard entry.configuration.cameraId == selected.id, entry.snapshot.image != nil else {
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

        print("Widget E2E passed")
        print("Camera: \(selected.displayName)")
        print("Configuration camera ID: \(selected.id)")
        print("Frame: \(entry.snapshot.image!.width)x\(entry.snapshot.image!.height)")
        print("Rendered: \(outputURL.path)")
    }
}
