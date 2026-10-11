import AppKit

enum AppIconAppearance {
    static func assetName(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "AppIcon-dark" : "AppIcon-light"
    }
    static func image(for appearance: NSAppearance, bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: assetName(for: appearance), withExtension: "png") else {
            return NSImage(named: NSImage.Name("AppIcon"))
        }
        return NSImage(contentsOf: url)
    }
}
