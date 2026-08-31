import SwiftUI

/// Brand logo from Resources/<name>.svg, rendered as a white template image.
/// The SVGs are authored at width="1em", so NSImage loads them 1x1 — the size
/// is set explicitly here and the vector rep scales to it.
struct ProviderIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        if let image = Self.load(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.white)
        }
    }

    private static var cache: [String: NSImage] = [:]

    private static func load(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            // A missing SVG renders as empty space, which hides the typo — fail
            // loudly in debug instead.
            assertionFailure("missing Resources/\(name).svg")
            return nil
        }
        image.size = CGSize(width: 64, height: 64)   // vector rep; scaled by .resizable()
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
