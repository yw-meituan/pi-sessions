import AppKit
import SwiftUI

enum StatusIconStyle: String, CaseIterable, Identifiable {
    case official, lucide, phosphor, phosphorBold, material
    var id: String { rawValue }
    var title: String {
        switch self {
        case .official: return "Official"
        case .lucide: return "Lucide"
        case .phosphor: return "Phosphor"
        case .phosphorBold: return "Phosphor Bold"
        case .material: return "Material"
        }
    }
    var assetName: String? {
        switch self {
        case .official: return nil
        case .lucide: return "lucide-pi"
        case .phosphor: return "phosphor-pi"
        case .phosphorBold: return "phosphor-pi-bold"
        case .material: return "mdi-pi"
        }
    }
}

// Fixed, bundled artwork only; no runtime downloads or repeated PNG decoding.
private let libraryIcons: [StatusIconStyle: NSImage] = Dictionary(uniqueKeysWithValues:
    StatusIconStyle.allCases.compactMap { style -> (StatusIconStyle, NSImage)? in
        guard let name = style.assetName,
              let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (style, image)
    })

struct StatusIconPreview: View {
    let style: StatusIconStyle
    var body: some View {
        if let image = makeStatusIcon(style: style) {
            Image(nsImage: image).renderingMode(style == .official ? .original : .template).resizable().scaledToFit()
        }
    }
}

func makeStatusIcon(style: StatusIconStyle = .official, indicator: Bool = false) -> NSImage? {
    if style == .official { return makeOfficialPiStatusIcon(indicator: indicator) }
    guard let artwork = libraryIcons[style] else { return makeOfficialPiStatusIcon(indicator: indicator) }
    let image = NSImage(size: NSSize(width: indicator ? 24 : 18, height: 18), flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        artwork.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        if indicator {
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: rect.maxX - 4, y: rect.maxY - 5, width: 3, height: 3))
        }
        return true
    }
    image.isTemplate = true
    return image
}

private func makeOfficialPiStatusIcon(indicator: Bool) -> NSImage {
    // Exact paths and sRGB colors from assets/pi-official.svg; only crop and scale.
    let artwork: [(NSColor, [CGPoint])] = [
        (NSColor(srgbRed: 240 / 255, green: 144 / 255, blue: 130 / 255, alpha: 1), [
            CGPoint(x: 165.29, y: 165.29), CGPoint(x: 517.36, y: 165.29),
            CGPoint(x: 517.36, y: 400), CGPoint(x: 400, y: 400),
            CGPoint(x: 400, y: 282.65), CGPoint(x: 165.29, y: 282.65),
        ]),
        (NSColor(srgbRed: 77 / 255, green: 154 / 255, blue: 191 / 255, alpha: 1), [
            CGPoint(x: 165.29, y: 282.65), CGPoint(x: 282.65, y: 282.65),
            CGPoint(x: 282.65, y: 400), CGPoint(x: 400, y: 400),
            CGPoint(x: 400, y: 517.36), CGPoint(x: 282.65, y: 517.36),
            CGPoint(x: 282.65, y: 634.72), CGPoint(x: 165.29, y: 634.72),
        ]),
        (NSColor(srgbRed: 241 / 255, green: 190 / 255, blue: 88 / 255, alpha: 1), [
            CGPoint(x: 517.36, y: 400), CGPoint(x: 634.72, y: 400),
            CGPoint(x: 634.72, y: 634.72), CGPoint(x: 517.36, y: 634.72),
        ]),
    ]
    let image = NSImage(size: NSSize(width: indicator ? 24 : 18, height: 18), flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.saveGState()
        context.translateBy(x: 2, y: 16)
        context.scaleBy(x: 14 / 469.43, y: -14 / 469.43)
        context.translateBy(x: -165.29, y: -165.29)
        for (color, points) in artwork {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
        if indicator {
            context.setFillColor(artwork[1].0.cgColor)
            context.fillEllipse(in: CGRect(x: rect.maxX - 4, y: rect.maxY - 5, width: 3, height: 3))
        }
        return true
    }
    image.isTemplate = false
    return image
}
