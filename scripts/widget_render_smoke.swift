import AppKit
import ImageIO
import SwiftUI
import WidgetKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Expected an image path")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: url)
guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Could not decode source image")
}

@MainActor
func verifyAccentedRender(_ image: CGImage) {
    let content = Image(decorative: image, scale: 1, orientation: .up)
        .resizable()
        .widgetAccentedRenderingMode(.fullColor)
        .aspectRatio(contentMode: .fill)
        .frame(width: 240, height: 160)
        .clipped()
        .environment(\.widgetRenderingMode, .accented)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    guard let rendered = renderer.nsImage,
          let tiff = rendered.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        fatalError("Could not render accented widget image")
    }

    var minimum = 1.0
    var maximum = 0.0
    var minimumAlpha = 1.0
    var maximumAlpha = 0.0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let luminance = 0.2126 * color.redComponent
                + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
            minimumAlpha = min(minimumAlpha, color.alphaComponent)
            maximumAlpha = max(maximumAlpha, color.alphaComponent)
        }
    }

    guard maximum - minimum > 0.2 || maximumAlpha - minimumAlpha > 0.2 else {
        fatalError("Accented widget render collapsed to a uniform field")
    }
    print("Accented widget render passed: luminance \(minimum)...\(maximum), alpha \(minimumAlpha)...\(maximumAlpha)")
}

await verifyAccentedRender(sourceImage)
