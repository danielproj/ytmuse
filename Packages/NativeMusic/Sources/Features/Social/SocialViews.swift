import DesignSystem
import SwiftUI

private struct SocialSurfaceKey: EnvironmentKey { static let defaultValue: SocialSurface? = nil }
public extension EnvironmentValues {
    var socialSurface: SocialSurface? {
        get { self[SocialSurfaceKey.self] }
        set { self[SocialSurfaceKey.self] = newValue }
    }
}

extension SocialOutboxEntry.Result {
    /// The words for the result, in the terms of what really happened: sent or not sent, confirmed or not.
    var message: String {
        switch self {
        case .pending: String(localized: "Sending…")
        case .confirmed: String(localized: "Done. YouTube Music confirmed it.")
        case .failed(let why, let sent): sent ? why : why + " " + String(localized: "Nothing was sent.")
        case .unconfirmed: String(localized: "YouTube Music didn’t confirm this. It may or may not have happened. Check before doing it again.")
        case .denied(let denial): denial.message + " " + String(localized: "Nothing was sent.")
        case .sourceUnresolved(let why): why + " " + String(localized: "Nothing was sent.")
        }
    }
    var symbol: String {
        switch self {
        case .pending: "ellipsis.circle"
        case .confirmed: "checkmark.circle"
        case .failed, .denied, .sourceUnresolved: "exclamationmark.circle"
        case .unconfirmed: "questionmark.circle"
        }
    }
}

/// The outcome of the last explicit social actions, newest first. It records; it never sends.
public struct SocialOutboxView: View {
    @Bindable var outbox: SocialOutbox
    public init(outbox: SocialOutbox) { self.outbox = outbox }
    public var body: some View {
        if !outbox.entries.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text("What you asked for").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(outbox.entries.prefix(5)) { entry in
                    Label { VStack(alignment: .leading, spacing: 0) {
                        Text(entry.subject).font(.callout)
                        Text(entry.result.message).font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    } } icon: { Image(systemName: entry.result.symbol) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("socialOutbox-" + entry.action.rawValue)
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("socialOutbox")
        }
    }
}

/// Comments, ratings and moderation for one song, where the source supplies them; otherwise the plain statement that it does not.
public struct SocialPanel: View {
    @Bindable var surface: SocialSurface
    let subject: SocialSubject
    @State private var draft = ""
    @State private var moderating: (offer: ModerationOffer, comment: SocialComment, confirmation: ModerationConfirmation)?
    public init(surface: SocialSurface, subject: SocialSubject) { self.surface = surface; self.subject = subject }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Comments").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
            content
            SocialOutboxView(outbox: surface.outbox)
        }
        .task(id: subject) { await surface.loadComments(subject) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("socialPanel")
        .confirmationDialog(moderating.map { String(localized: "\($0.offer.title) the comment by \($0.confirmation.author)?") } ?? "",
                            isPresented: Binding(get: { moderating != nil }, set: { if !$0 { moderating = nil } }), titleVisibility: .visible, presenting: moderating) { pending in
            Button(pending.offer.title, role: .destructive) { Task { await surface.moderate(pending.offer, comment: pending.comment, on: subject, confirmation: pending.confirmation) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("This sends the request to YouTube Music for the comment “\(pending.confirmation.text)” by \(pending.confirmation.author).")
        }
    }
    @ViewBuilder private var content: some View {
        switch surface.state(subject) {
        case .unresolved(let reason):
            Label(reason, systemImage: "bubble.left.and.exclamationmark.bubble.right").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsUnresolved")
        case .idle, .loading:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading comments"))
        case .signInRequired:
            Label("Sign in to YouTube Music to read comments.", systemImage: "person.crop.circle.badge.questionmark").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsSignIn")
        case .failed(let failure):
            HStack { Label(failure.message, systemImage: "exclamationmark.circle").foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("socialCommentsFailed")
                Button("Retry") { Task { await surface.loadComments(subject) } }.musicButtons() }
        case .loaded(let page):
            if page.comments.isEmpty { Text("No comments yet.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsEmpty") }
            ForEach(page.comments) { comment in
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(comment.author).font(.callout.weight(.semibold))
                        if let posted = comment.posted { Text(posted).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                        Spacer()
                        if !comment.moderation.isEmpty {
                            Menu("Moderate") {
                                ForEach(comment.moderation) { offer in
                                    Button(offer.title, role: offer.destructive ? .destructive : nil) {
                                        if offer.destructive, let confirmation = surface.confirmation(for: offer, comment: comment, on: subject) { moderating = (offer, comment, confirmation) } else if !offer.destructive { Task { await surface.moderate(offer, comment: comment, on: subject) } }
                                    }
                                }
                            }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("socialModerate-" + comment.id)
                        }
                    }
                    Text(comment.text).font(.body)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("socialComment-" + comment.id)
            }
            if page.canPost {
                HStack(alignment: .top) {
                    TextField("Add a comment", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).accessibilityIdentifier("socialDraft")
                    Button("Post") {
                        let text = draft
                        Task { if await surface.post(text, on: subject) == .confirmed { draft = "" } }
                    }.musicButtons(prominent: true).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || surface.busy.contains(subject)).accessibilityIdentifier("socialPost")
                }
            } else {
                Text("YouTube Music didn’t offer commenting here.").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCannotPost")
            }
        }
    }
}
