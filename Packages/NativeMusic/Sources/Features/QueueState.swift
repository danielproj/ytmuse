import Domain
import Queue
import Foundation
import Observation

/// Feature-scoped state shared by queue row/keyboard/menu bindings. UI rendering stays native.
@MainActor @Observable public final class QueueState {
    public private(set) var snapshot: QueueSnapshot?
    public private(set) var error: String?
    public private(set) var isWorking = false
    public private(set) var replacementNeedsDecision = false
    public private(set) var playlistIntent: SaveQueuePlaylistIntent?
    private var pendingCommands = 0
    private let commands: QueueCommands
    private let context: RequestContext
    public init(commands: QueueCommands, context: RequestContext) { self.commands = commands; self.context = context }
    public var currentOccurrence: UUID? { snapshot?.session.currentOccurrence }
    public func refresh() async { snapshot = try? await commands.snapshot() }
    public func send(_ command: QueueCommand, origin: CommandOrigin = .userInterface) async {
        pendingCommands += 1; isWorking = true
        defer { pendingCommands -= 1; isWorking = pendingCommands > 0 }
        error = nil; replacementNeedsDecision = false
        do { _ = try await commands.execute(command, context: context, origin: origin); snapshot = try await commands.snapshot() }
        catch QueueError.confirmationRequired { replacementNeedsDecision = true; snapshot = try? await commands.snapshot() }
        catch { self.error = SafeErrorText.describe(error); snapshot = try? await commands.snapshot() }
    }
    public func prepareSaveAsPlaylist() async {
        do { playlistIntent = try await commands.playlistIntent(context: context); error = nil }
        catch { self.error = SafeErrorText.describe(error) }
    }
}
