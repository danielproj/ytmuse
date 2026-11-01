// Read only native resource resolution. No UI automation or screenshot substitute.
import AppKit
import Foundation

let appPath = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let bundle = Bundle(path: appPath)!
let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String
precondition(iconName == "YTMuse")
let image = bundle.image(forResource: "YTMuse")!
precondition(!image.representations.isEmpty)
var results: [[String: Any]] = []
var draws: [Data] = []
for (name, appearance) in [("Aqua", NSAppearance.Name.aqua), ("DarkAqua", .darkAqua)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
    }
    let png = bitmap.representation(using: .png, properties: [:])!
    draws.append(png)
    try png.write(to: output.appendingPathComponent("bundle-icon-\(name).png"))
    results.append(["appearance": name, "representations": image.representations.count, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
}
let menu = bundle.image(forResource: "YTMuseMenuTemplate")!
menu.isTemplate = true
precondition(menu.isTemplate)
let summary: [String: Any] = ["iconName": iconName!, "nativeBundleResolution": results, "menuTemplate": menu.isTemplate, "drawsByteIdentical": draws[0] == draws[1], "appearanceAdaptationDemonstrated": false, "drawEvidence": "resource_presence_only", "note": "Both AppKit draws resolve the flattened actool YTMuse.icns and are byte-identical. They prove resource presence only. Adaptive evidence is compiled Assets.car stacks, actual Icon Composer modes and ictool exports; no desktop appearance switching claim."]
print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
