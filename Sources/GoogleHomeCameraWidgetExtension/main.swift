import SwiftUI
import WidgetKit

private enum SnapshotStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GoogleHomeCameraWidget", isDirectory: true)
    }

    static var imageURL: URL {
        directory.appendingPathComponent("latest-snapshot.png")
    }

    static var metadataURL: URL {
        directory.appendingPathComponent("latest-snapshot.json")
    }

    static func load() -> CameraSnapshot {
        let image = NSImage(contentsOf: imageURL)
        let metadata = try? JSONDecoder().decode(SnapshotMetadata.self, from: Data(contentsOf: metadataURL))
        return CameraSnapshot(
            image: image,
            cameraName: metadata?.cameraName ?? "Google Nest Camera",
            updatedAt: metadata?.updatedAt
        )
    }
}

private struct SnapshotMetadata: Decodable {
    let cameraName: String
    let updatedAt: Date
}

private struct CameraSnapshot {
    let image: NSImage?
    let cameraName: String
    let updatedAt: Date?
}

private struct CameraSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: CameraSnapshot
}

private struct CameraSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(date: Date(), snapshot: CameraSnapshot(image: nil, cameraName: "Google Nest Camera", updatedAt: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (CameraSnapshotEntry) -> Void) {
        completion(CameraSnapshotEntry(date: Date(), snapshot: SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CameraSnapshotEntry>) -> Void) {
        let now = Date()
        let entry = CameraSnapshotEntry(date: now, snapshot: SnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
    }
}

private struct CameraSnapshotWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        content
            .widgetBackground()
    }

    private var content: some View {
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
                    Text("Open the camera viewer to create a snapshot.")
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
    }
}

private extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(.black, for: .widget)
        } else {
            background(Color.black)
        }
    }
}

private struct GoogleHomeCameraSnapshotWidget: Widget {
    let kind = "GoogleHomeCameraSnapshotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CameraSnapshotProvider()) { entry in
            CameraSnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName("Nest Camera Snapshot")
        .description("Shows the latest snapshot captured from the companion camera viewer.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
private struct GoogleHomeCameraWidgetBundle: WidgetBundle {
    var body: some Widget {
        GoogleHomeCameraSnapshotWidget()
    }
}
