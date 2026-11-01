// Read-only analysis of owned native-window captures, using XCTest-recorded text bounds.
import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
func linear(_ c: CGFloat) -> Double { let x = Double(c); return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4) }
func percentile(_ values: [Double], _ p: Double) -> Double { values[min(values.count-1, Int(Double(values.count-1)*p))] }
var results: [[String: Any]] = []
for file in files.filter({ $0.lastPathComponent.hasSuffix("-metrics.json") }).sorted(by: { $0.path < $1.path }) {
    let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let mode = data["mode"] as! String
    let window = data["window"] as! [String: Double], text = data["text"] as! [String: Double]
    let image = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("T50-\(mode).png")))!
    let sx = Double(image.pixelsWide)/window["width"]!, sy = Double(image.pixelsHigh)/window["height"]!
    let x0 = max(0, Int((text["x"]!-window["x"]!)*sx)), y0 = max(0, Int((text["y"]!-window["y"]!)*sy))
    let x1 = min(image.pixelsWide, x0+Int(text["width"]!*sx)), y1 = min(image.pixelsHigh, y0+Int(text["height"]!*sy))
    precondition(x1>x0 && y1>y0, "Text region must be nonempty and visible")
    var luminances: [Double] = []
    for y in y0..<y1 { for x in x0..<x1 {
        let c = image.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
        luminances.append(0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent))
    } }
    luminances.sort()
    let background = percentile(luminances, 0.5)
    let dark = mode.contains("dark")
    let ink = luminances.filter { dark ? $0>background+0.05 : $0<background-0.05 }
    precondition(ink.count>20, "Text ink must be measured; blank regions cannot pass")
    let foreground = percentile(ink, dark ? 0.95 : 0.05)
    let ratio = (max(background,foreground)+0.05)/(min(background,foreground)+0.05)
    let backgroundKind = mode.contains("accounts") ? "canvas" : (mode.contains("transparency") || mode.contains("contrast") ? "opaque" : "glass")
    results.append(["background":backgroundKind,"mode":mode,"textCoreToLocalBackgroundRatio":ratio,"samplePixels":luminances.count,"inkPixels":ink.count,"normalTextTarget":4.5,"meetsSampleTarget":ratio>=4.5])
}
precondition(results.count == 15)
print(String(data: try JSONSerialization.data(withJSONObject: ["method":"Median local background versus 5th/95th percentile text-core luminance within recorded text bounds; sRGB WCAG contrast; antialias edge pixels excluded. Samples only, not full accessibility certification.","samples":results], options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
precondition(results.allSatisfy { $0["meetsSampleTarget"] as! Bool })
