// swift-tools-version: 6.4
import PackageDescription
// W25: the widget extension itself is the Xcode target `NativeMusicWidget` (Extensions/Sources/NativeMusicWidget), built from App/NativeMusic.xcodeproj; its
// shared code is the `WidgetShared` product of Packages/NativeMusic. This package keeps only the intent scaffold; it embeds and registers nothing.
let package = Package(
    name: "NativeMusicExtensions",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NativeMusicIntentSupport", targets: ["NativeMusicIntentSupport"])
    ],
    targets: [
        .target(name: "NativeMusicIntentSupport")
    ]
)
