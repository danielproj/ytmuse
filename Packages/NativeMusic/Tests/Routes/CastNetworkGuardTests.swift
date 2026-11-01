import Foundation
import Testing
@testable import OutputRoutes

/// W39 real-network safety. No test target may reach the real Bonjour browser, a connection to a receiver, or a listening socket on a non-loopback interface:
/// the runtime gate (`CastNetworkGate`) refuses them in a test process, and these source sweeps fail if a test or a source puts one where it does not belong.
/// Each rule proves it can fire on its own sample and each sweep proves it read something. The guard tests never perform the protected action: they test
/// the decision functions and read source text.
@Suite struct CastNetworkGuardTests {
    static let packageRoot = OutputRoutesGuardTests.packageRoot
    static let repositoryRoot = OutputRoutesGuardTests.repositoryRoot

    /// Names that begin a real browse, a real connection to a device, a listening socket or the real-network switch.
    static let testForbidden = ["NWBrowser", "NetServiceBrowser", "NetService\\b", "NWListener", "NWCastDirectory", "NWCastChannel", "enableLive", "getifaddrs", "INADDR_ANY", "SO_REUSEPORT",
                                "dnssd", "DNSServiceBrowse", "_googlecast"]
    /// Comments and the contents of string literals are not code: other lanes' guard tests list API names as strings.
    static func executable(_ text: String) -> String {
        OutputRoutesGuardTests.code(text).replacingOccurrences(of: "\"(?:\\\\.|[^\"\\\\\\n])*\"", with: "\"\"", options: .regularExpression)
    }
    static func hits(_ patterns: [String], in text: String) -> [String] { patterns.filter { text.range(of: $0, options: .regularExpression) != nil } }
    static func testSources() -> [URL] {
        OutputRoutesGuardTests.swiftFiles(under: packageRoot.appendingPathComponent("Tests")) + OutputRoutesGuardTests.swiftFiles(under: repositoryRoot.appendingPathComponent("Tests"))
    }

    @Test func noTestSourceCanReachTheRealNetwork() throws {
        var swept = 0
        for file in Self.testSources() where !["CastNetworkGuardTests.swift", "OutputRoutesGuardTests.swift"].contains(file.lastPathComponent) {
            swept += 1
            let found = Self.hits(Self.testForbidden, in: Self.executable(try String(contentsOf: file, encoding: .utf8)))
            #expect(found.isEmpty, "\(file.path) names \(found)")
        }
        #expect(swept > 100, "the sweep read \(swept) test files; an empty sweep proves nothing")
    }
    @Test func theOnlyRelayAddressATestLiteralNamesIsLoopback() throws {
        var literals = 0
        for file in Self.testSources() {
            let text = OutputRoutesGuardTests.code(try String(contentsOf: file, encoding: .utf8))
            for match in text.matches(of: /CastRelayServer\(bindAddress:\s*"([^"]+)"/) {
                literals += 1
                let address = String(match.output.1)
                let ok = address == "127.0.0.1" || file.lastPathComponent == "CastRelayTests.swift" && ["192.168.1.20", "10.1.2.3", "172.16.5.5", "169.254.9.9"].contains(address)
                #expect(ok, "\(file.lastPathComponent) binds \(address)")
            }
        }
        #expect(literals >= 1, "saw \(literals) relay constructions")
    }
    /// A raw socket that listens (BSD `bind`/`listen`/`accept`), in any test target: its file must bind the literal 127.0.0.1 and name no other address.
    static let socketListening = "Darwin\\.(bind|listen|accept)\\(|(?<![.\\w])(bind|listen|accept)\\(\\s*\\w*(fd|sock|descriptor|listener)\\w*\\s*,|(?<![.\\w])(bind|listen)\\(\\s*listener"
    @Test func everySocketATestOpensIsLoopbackOnly() throws {
        var listeningFiles = Set<String>(), addressFiles = Set<String>()
        for file in Self.testSources() where file.lastPathComponent != "CastNetworkGuardTests.swift" {
            let text = Self.executableKeepingStrings(try String(contentsOf: file, encoding: .utf8))
            let literals = text.matches(of: /inet_addr\(\s*"([^"]*)"/).map { String($0.output.1) }
            if !literals.isEmpty { addressFiles.insert(file.lastPathComponent) }
            #expect(literals.allSatisfy { $0 == "127.0.0.1" }, "\(file.lastPathComponent) names an address other than 127.0.0.1: \(literals)")
            #expect(!text.contains("INADDR_ANY") && !text.contains("INADDR_BROADCAST"), "\(file.lastPathComponent)")
            if text.range(of: Self.socketListening, options: .regularExpression) != nil {
                listeningFiles.insert(file.lastPathComponent)
                #expect(literals == ["127.0.0.1"], "\(file.lastPathComponent) listens but does not bind exactly the loopback literal: \(literals)")
            }
        }
        #expect(["CastTestSupport.swift", "CastAppSupport.swift"].allSatisfy(addressFiles.contains), "the Cast support clients were read: \(addressFiles)")
        #expect(!listeningFiles.contains("CastTestSupport.swift") && !listeningFiles.contains("CastAppSupport.swift"), "the Cast tests only ever CONNECT (to loopback)")
    }
    static func executableKeepingStrings(_ text: String) -> String { OutputRoutesGuardTests.code(text) }

    @Test func theRealNetworkTypesLiveInExactlyTheirFiles() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        var homes: [String: Set<String>] = [:]
        let names = ["NWBrowser", "NWListener", "NWCastDirectory", "NWCastChannelFactory", "NWCastChannel", "enableLive", "NWConnection", "bonjourWithTXTRecord", "sec_protocol_options_set_verify_block"]
        for file in OutputRoutesGuardTests.swiftFiles(under: sources) {
            let text = OutputRoutesGuardTests.code(try String(contentsOf: file, encoding: .utf8))
            for name in names where text.contains(name) { homes[name, default: []].insert(file.lastPathComponent) }
        }
        let expected: [String: Set<String>] = [
            "NWBrowser": ["CastNetwork.swift"], "bonjourWithTXTRecord": ["CastNetwork.swift"], "sec_protocol_options_set_verify_block": ["CastNetwork.swift"],
            "NWListener": ["NativeOAuthLoopback.swift", "CastRelayServer.swift"],   // the sign-in redirect's loopback listener (W07) and the Cast relay's
            "NWCastDirectory": ["CastNetwork.swift", "OutputComposition.swift"], "NWCastChannelFactory": ["CastNetwork.swift", "OutputComposition.swift"], "NWCastChannel": ["CastNetwork.swift", "OutputComposition.swift"],
            "enableLive": ["CastNetworkGate.swift", "OutputComposition.swift"],
            // Connections: the receiver channel, the relay's accepted connections, and the pre-existing AirPlay and CoreAudio code does not use them.
            "NWConnection": ["NativeOAuthLoopback.swift", "CastNetwork.swift", "CastRelayServer.swift"],
        ]
        for (name, files) in expected { #expect(homes[name] == files, "\(name): \(homes[name] ?? [])") }
        #expect(Set(homes.keys) == Set(expected.keys), "\(homes.keys.sorted())")
    }
    @Test func everyRealNetworkEntryPointAsksTheGateFirst() throws {
        let cast = Self.packageRoot.appendingPathComponent("Sources/OutputRoutes/Cast")
        func text(_ name: String) throws -> String { OutputRoutesGuardTests.code(try String(contentsOf: cast.appendingPathComponent(name), encoding: .utf8)) }
        let network = try text("CastNetwork.swift")
        #expect(network.contains("guard browser == nil, (try? CastNetworkGate.requireLive()) != nil else { return }"), "browsing asks the gate before creating a browser")
        #expect(network.contains("do { try CastNetworkGate.requireLive() } catch { throw CastError.networkNotPermitted }"), "opening a channel asks the gate before creating a connection")
        let server = try text("CastRelayServer.swift")
        #expect(server.contains("try CastNetworkGate.requireBindable(bindAddress)"), "the relay asks the gate before it exists")
        #expect(server.contains("requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: .any)") && server.contains("acceptLocalOnly = true"), "bound to ONE address, local networks only")
        #expect(!server.contains("0.0.0.0") && !server.contains("::"), "no wildcard address")
        #expect(server.contains("CastNetworkGate.peerAllowed("), "connections are checked against the receiver's address")
        let gate = try text("CastNetworkGate.swift")
        #expect(gate.contains("guard !isTestProcess else { throw Refusal.testProcess }"), "the switch cannot be turned on in a test process")
        #expect(gate.contains("try requireLive()") && gate.contains("if ip.isLoopback { return }"))
    }
    @Test func browsingStartsOnlyFromTheControllersPickerPath() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        var callers = Set<String>()
        for file in OutputRoutesGuardTests.swiftFiles(under: sources) {
            let text = OutputRoutesGuardTests.code(try String(contentsOf: file, encoding: .utf8))
            if text.contains(".startBrowsing()") { callers.insert(file.lastPathComponent) }
        }
        #expect(callers == ["OutputController.swift"], "\(callers)")
        let controller = OutputRoutesGuardTests.code(try String(contentsOf: sources.appendingPathComponent("AppShell/Output/OutputController.swift"), encoding: .utf8))
        #expect(controller.components(separatedBy: ".startBrowsing()").count == 2, "exactly one call, inside updateCastBrowsing")
        #expect(controller.contains("if pickerIsOpen || cast?.isLive == true { castDirectory.startBrowsing() }"))
        let composition = OutputRoutesGuardTests.code(try String(contentsOf: sources.appendingPathComponent("AppShell/Output/OutputComposition.swift"), encoding: .utf8))
        #expect(!composition.contains("startBrowsing"), "the composition (launch) never starts browsing")
    }
    @Test func theIsolatedLaunchGetsOnlyScriptedCastPieces() throws {
        let composition = OutputRoutesGuardTests.code(try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/AppShell/Output/OutputComposition.swift"), encoding: .utf8))
        let isolated = try #require(composition.components(separatedBy: "if IsolatedQAStorage.requested() {").dropFirst().first?.components(separatedBy: "return\n        }").first)
        #expect(isolated.contains("ScriptedCastDirectory()") && isolated.contains("SimulatedCastReceiver()"))
        #expect(!isolated.contains("NWCast") && !isolated.contains("enableLive"))
        let real = try #require(composition.components(separatedBy: "if (try? CastNetworkGate.enableLive()) != nil {").dropFirst().first)
        #expect(real.contains("NWCastDirectory()") && real.contains("NWCastChannelFactory(directory: directory)"))
        // The simulation exists in Debug builds only.
        let simulation = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/OutputRoutes/Cast/SimulatedCastReceiver.swift"), encoding: .utf8)
        #expect(simulation.hasPrefix("#if DEBUG") && simulation.hasSuffix("#endif\n"))
    }
    @Test func theAppAsksForLocalNetworkAccessWithAStatedReasonAndOnlyForCast() throws {
        let plist = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>NSLocalNetworkUsageDescription</key>") && plist.contains("<string>_googlecast._tcp</string>"))
        #expect(plist.contains("It asks only when you open the output menu."))
        #expect(!plist.contains("_airplay") && !plist.contains("NSBluetooth"), "no other network or Bluetooth discovery is declared")
    }

    // MARK: The decision functions themselves (nothing is opened)

    @Test func theGateRefusesInATestProcessAndRefusesEveryNonLocalAddress() {
        #expect(CastNetworkGate.isTestProcess)
        #expect(throws: CastNetworkGate.Refusal.testProcess) { try CastNetworkGate.requireLive() }
        #expect(!CastNetworkGate.isLive)
        for address in ["0.0.0.0", "8.8.8.8", "100.64.0.1", "172.32.0.1", "224.0.0.251", "255.255.255.255"] { #expect(throws: CastNetworkGate.Refusal.self) { try CastNetworkGate.requireBindable(address) }; _ = address }
        for address in ["::", "::1", "fe80::1", "", "localhost", "host.local"] { #expect(throws: CastNetworkGate.Refusal.self) { try CastNetworkGate.requireBindable(address) } }
        for loopback in ["127.0.0.1", "127.1.2.3"] { #expect(throws: Never.self) { try CastNetworkGate.requireBindable(loopback) } }
        // A real LAN address needs the switch, which is off here: refused for that reason and no other.
        for lan in ["192.168.0.5", "10.0.0.5", "172.16.0.5", "169.254.1.1"] { #expect(throws: CastNetworkGate.Refusal.testProcess) { try CastNetworkGate.requireBindable(lan) } }
    }
    @Test func peersAreMatchedByExactAddress() {
        #expect(CastNetworkGate.peerAllowed("192.168.1.50", receiver: "192.168.1.50", boundTo: "192.168.1.20"))
        for peer in ["192.168.1.51", "192.168.1.5", "192.168.1.500", "127.0.0.1", "", "::1", "192.168.1.50%en0"] { #expect(!CastNetworkGate.peerAllowed(peer, receiver: "192.168.1.50", boundTo: "192.168.1.20"), "\(peer)") }
        #expect(CastNetworkGate.peerAllowed("127.0.0.1", receiver: nil, boundTo: "127.0.0.1") && !CastNetworkGate.peerAllowed("10.0.0.1", receiver: nil, boundTo: "127.0.0.1"))
        #expect(!CastNetworkGate.peerAllowed("192.168.1.50", receiver: nil, boundTo: "192.168.1.20"), "no receiver address: nobody")
    }
    @Test func addressesAreParsedStrictly() {
        for bad in ["1.2.3", "1.2.3.4.5", "01.2.3.4", "1.2.3.256", "1..2.3", " 1.2.3.4", "1.2.3.4 ", "a.b.c.d", "+1.2.3.4", "1.2.3.-4", "1.2.3.4\n"] { #expect(CastNetworkGate.IPv4(bad) == nil, "\(bad.debugDescription)") }
        #expect(CastNetworkGate.IPv4("192.168.1.1")?.isPrivateLAN == true && CastNetworkGate.IPv4("172.31.255.255")?.isPrivateLAN == true && CastNetworkGate.IPv4("172.32.0.0")?.isPrivateLAN == false)
        #expect(CastNetworkGate.IPv4("169.254.0.1")?.isPrivateLAN == true && CastNetworkGate.IPv4("100.64.0.1")?.isPrivateLAN == false)
    }

    // MARK: The sweep rules fire on their own samples

    @Test func everyRuleFiresOnItsOwnSample() {
        for sample in ["let b = NWBrowser(for: d, using: p)", "NetServiceBrowser()", "let l = try NWListener(using: .tcp)", "NWCastChannelFactory(directory: d)", "try CastNetworkGate.enableLive()",
                       "INADDR_ANY", "DNSServiceBrowse(&r, 0, 0, \"_x\", nil, cb, nil)"] {
            #expect(!Self.hits(Self.testForbidden, in: sample).isEmpty, "\(sample)")
        }
        #expect(Self.hits(Self.testForbidden, in: Self.executable("let names = [\"NWBrowser\", \"enableLive\"]; let escaped = \"a \\\"NWListener\\\" b\"")).isEmpty, "a name inside a string literal is text, not a use")
        #expect(!Self.hits(Self.testForbidden, in: Self.executable("let s = \"x\"; let b = NWBrowser(for: d, using: p)")).isEmpty, "code after a string literal on the same line is still seen")
        for sample in ["Darwin.listen(fd, 5)", "bind(fd, &a, 16)", "bind(listener, p, 16)", "accept(socketHandle, nil, nil)", "_ = bind(sock, $0, 16)"] {
            #expect(sample.range(of: Self.socketListening, options: .regularExpression) != nil, "\(sample)")
        }
        #expect("let rebind = 1; account.bind(request); try await store.bind(context); unlisten(x)".range(of: Self.socketListening, options: .regularExpression) == nil)
        #expect(Self.hits(Self.testForbidden, in: OutputRoutesGuardTests.code("// NWBrowser is never created in a test")).isEmpty, "a comment is not a call")
        #expect(Self.hits(Self.testForbidden, in: "let rebind = 1; let unlisten = 2; account.bind(request); try await store.bind(context)").isEmpty, "bind( inside another word, or a method named bind, is not the socket call")
    }
}
