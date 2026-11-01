import AppKit

/// The matching generated 1x/2x menu mark is bundled now for W21's status item.
public enum BrandAssets {
    @MainActor public static func menuBarTemplate() -> NSImage? {
        guard let image = Bundle.main.image(forResource: "YTMuseMenuTemplate") else { return nil }
        image.isTemplate = true
        return image
    }
}
