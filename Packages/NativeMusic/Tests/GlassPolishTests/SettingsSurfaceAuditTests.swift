import AppKit
import SwiftUI
import Testing
import DesignSystem
@testable import AppShell

/// The real Settings split view at its minimum and preferred sizes, in both appearances.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct SettingsSurfaceAuditTests {
    @Test(arguments: AuditScheme.allCases)
    func settingsColumnsStayInsideTheWindow(_ scheme: AuditScheme) async throws {
        await RenderGate.enter()
        defer { RenderGate.leave() }
        let accounts = LocalAccountBootstrap()
        await accounts.load()
        #expect(!accounts.failure)
        for size in [AuditSize(name: "settingsMinimum", width: 780, height: 560), AuditSize(name: "settingsPreferred", width: 820, height: 620)] {
            let host = AuditHost(SettingsWindow(accounts: accounts), size: size, scheme: scheme)
            await host.settleUntilReported(["settingsSidebar", "settingsDetail"])
            let sidebar = try #require(host.box.frames.first { $0.tag.name == "settingsSidebar" }?.rect)
            let detail = try #require(host.box.frames.first { $0.tag.name == "settingsDetail" }?.rect)
            #expect(sidebar.width >= 180 && sidebar.width <= 260, "sidebar: \(sidebar)")
            #expect(detail.width > 400)
            #expect(abs(sidebar.minX - host.bounds.minX) <= 1)
            #expect(abs(detail.maxX - host.bounds.maxX) <= 1)
            #expect(abs(detail.minX - sidebar.maxX) <= 1)
            for rect in [sidebar, detail] {
                #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(rect))
                #expect(abs(rect.maxY - host.bounds.maxY) <= 1)
                // Only the top edge may reserve space for the native titlebar/toolbar.
                #expect(rect.minY >= host.bounds.minY - 1)
                #expect(rect.minY <= host.bounds.minY + 60)
            }
            host.close()
        }
        await accounts.shutdown()
        await accounts.isolatedStorage?.destroy()
    }
}
