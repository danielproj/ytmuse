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
                        Text(verbatim: entry.result.message).font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText)
                    } } icon: { Image(systemName: entry.result.symbol) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("socialOutbox-" + entry.action.rawValue)
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("socialOutbox")
        }
    }
}

/// Comments for one song, read when the person asks, where the source supplies them; otherwise the plain statement of what is and is not available.
///
/// Nothing here reads on its own: the panel appearing, the page being scrolled to or a row coming into view sends nothing. Show comments, a sort
/// order, More comments and a thread's replies are each one button and one request, and a bound that is reached is stated, never silent.
/// Posting and moderation are offered only while the transport says it has a verified write route (it does not yet): no composer, no menu.
public struct SocialPanel: View {
    @Bindable var surface: SocialSurface
    let subject: SocialSubject
    @State private var draft = ""
    @State private var moderating: (offer: ModerationOffer, comment: SocialComment, confirmation: ModerationConfirmation)?
    public init(surface: SocialSurface, subject: SocialSubject) { self.surface = surface; self.subject = subject }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Comments").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader).accessibilityIdentifier("socialCommentsHeader")
            if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
            content
            SocialOutboxView(outbox: surface.outbox)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("socialPanel")
        .confirmationDialog(moderating.map { String(localized: "\($0.offer.title) the comment by \($0.confirmation.author)?") } ?? "",
                            isPresented: Binding(get: { moderating != nil }, set: { if !$0 { moderating = nil } }), titleVisibility: .visible, presenting: moderating) { pending in
            Button(pending.offer.title, role: .destructive) { Task { await surface.moderate(pending.offer, comment: pending.comment, on: subject, confirmation: pending.confirmation) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("This sends the request to YouTube Music for the comment “\(pending.confirmation.text)” by \(pending.confirmation.author).")
        }
    }
    private func show() { Task { await surface.loadComments(subject) } }
    @ViewBuilder private var content: some View {
        switch surface.state(subject) {
        case .unresolved(let reason):
            Label(reason, systemImage: "bubble.left.and.exclamationmark.bubble.right").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsUnresolved")
        case .idle:
            Button("Show comments") { show() }.musicPageAction().accessibilityIdentifier("socialShow")
        case .loading:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading comments")).accessibilityIdentifier("socialCommentsLoading")
        case .notOffered:
            Label("Comments aren’t offered here.", systemImage: "bubble.left").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsNotOffered")
        case .serviceMessage(let message):
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Label { Text(verbatim: message) } icon: { Image(systemName: "info.circle") }.font(.callout).accessibilityIdentifier("socialCommentsMessage")
                Text("This is YouTube Music’s own message for this song.").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText)
                Button("Show comments again") { show() }.musicPageAction().accessibilityIdentifier("socialReopen")
            }
        case .failed(let failure):
            HStack { Label(failure.message, systemImage: "exclamationmark.circle").foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("socialCommentsFailed")
                if failure == .outOfDate { Button("Show comments again") { show() }.musicPageAction().accessibilityIdentifier("socialReopen") }
                else { Button("Retry") { show() }.musicPageAction().accessibilityIdentifier("socialRetry") } }
        case .loaded(let list):
            loaded(list)
        }
    }
    @ViewBuilder private func loaded(_ list: CommentsList) -> some View {
        if let header = list.header {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if let count = header.countText { Text(verbatim: count).font(.callout.weight(.semibold)).accessibilityIdentifier("socialCount") }
                if !header.sorts.isEmpty {
                    HStack {
                        ForEach(Array(header.sorts.enumerated()), id: \.offset) { index, option in
                            MusicChip(verbatim: option.title, isSelected: option.isSelected) { Task { await surface.selectSort(option, for: subject) } }.disabled(option.isSelected || list.sorting || list.needsReopen)
                                .accessibilityAddTraits(option.isSelected ? .isSelected : []).accessibilityIdentifier("socialSort-\(index)")
                        }
                        if list.sorting { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading comments")) }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("socialSort")
                }
            }
        }
        if let failure = list.sortFailure {
            Label(failure.message, systemImage: "exclamationmark.circle").foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("socialSortFailed")
        }
        if list.needsReopen {
            Button("Show comments again") { show() }.musicPageAction().accessibilityIdentifier("socialReopen")
        }
        if list.threads.isEmpty { Text("No comments yet.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCommentsEmpty") }
        ForEach(list.threads) { thread in
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                row(thread.comment)
                ForEach(list.shownReplies(of: thread)) { reply in
                    row(reply).padding(.leading, MusicSpace.nestedIndent(level: reply.level))
                }
                replyControls(list, thread)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("socialThread-" + thread.id)
        }
        moreControls(list)
        composer(list)
    }
    private func row(_ comment: SocialComment) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: comment.author).font(.callout.weight(.semibold))
                if comment.isVerified { Text("Verified").font(.caption2).foregroundStyle(MusicStyle.secondaryText) }
                if comment.isCreator { Text("Creator").font(.caption2).foregroundStyle(MusicStyle.secondaryText) }
                if comment.isArtist { Text("Artist").font(.caption2).foregroundStyle(MusicStyle.secondaryText) }
                if comment.isCurrentUser { Text("You").font(.caption2).foregroundStyle(MusicStyle.secondaryText) }
                if let posted = comment.posted { Text(verbatim: posted).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                Spacer()
                if !comment.moderation.isEmpty, surface.writesUnresolved == nil {
                    Menu("Moderate") {
                        ForEach(comment.moderation) { offer in
                            Button(offer.title, role: offer.destructive ? .destructive : nil) {
                                if offer.destructive, let confirmation = surface.confirmation(for: offer, comment: comment, on: subject) { moderating = (offer, comment, confirmation) } else if !offer.destructive { Task { await surface.moderate(offer, comment: comment, on: subject) } }
                            }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("socialModerate-" + comment.id)
                }
            }
            // The text is shown as written: a plain string, never parsed for links or styling, and nothing in it is activated.
            Text(verbatim: comment.text).font(.body)
            if let likes = comment.likeCountText { Text("Likes: \(likes)").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier((comment.level == 0 ? "socialComment-" : "socialReply-") + comment.id)
    }
    @ViewBuilder private func replyControls(_ list: CommentsList, _ thread: CommentThread) -> some View {
        let entry = list.replies[thread.id]
        let blocked = list.sorting || list.needsReopen
        if (entry?.pages ?? 0) == 0, thread.repliesToken != nil {
            Button { Task { await surface.loadReplies(subject, of: thread.id) } } label: {
                if let count = thread.comment.replyCountText { Text("View replies (\(count))") } else { Text("View replies") }
            }.buttonStyle(.link).disabled(entry?.loading == true || blocked).accessibilityIdentifier("socialReplies-" + thread.id)
        } else if (entry?.pages ?? 0) == 0, let count = thread.comment.replyCountText, thread.inlineReplies.isEmpty {
            Text("Replies: \(count)").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialReplyCount-" + thread.id)
        } else if entry?.next != nil, !list.reachedReplyBound(thread) {
            Button("More replies") { Task { await surface.loadReplies(subject, of: thread.id) } }
                .buttonStyle(.link).disabled(entry?.loading == true || blocked).accessibilityIdentifier("socialMoreReplies-" + thread.id)
        }
        if entry?.loading == true { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading replies")) }
        if let failure = entry?.failure {
            Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("socialRepliesFailed-" + thread.id)
        }
        if list.reachedReplyBound(thread) {
            Text("Showing the first \(String(SocialSurface.maximumReplyPages)) pages of replies. This app doesn’t load more.")
                .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialRepliesBound-" + thread.id)
        }
    }
    @ViewBuilder private func moreControls(_ list: CommentsList) -> some View {
        if list.next != nil, !list.reachedPageBound {
            HStack {
                Button("More comments") { Task { await surface.loadMoreComments(subject) } }
                    .musicPageAction().disabled(list.loadingMore || list.sorting || list.needsReopen).accessibilityIdentifier("socialMore")
                if list.loadingMore { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading comments")) }
            }
        }
        if let failure = list.moreFailure {
            Label(failure.message, systemImage: "exclamationmark.circle").foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("socialMoreFailed")
        }
        if list.reachedPageBound {
            Text("Showing the first \(String(SocialSurface.maximumCommentPages)) pages of comments. This app doesn’t load more.")
                .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialBound")
        }
    }
    @ViewBuilder private func composer(_ list: CommentsList) -> some View {
        if let reason = surface.writesUnresolved {
            // No composer, no draft, no Post: this app has no verified route to write, and says so in its own words.
            Label(reason, systemImage: "lock").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialWritesUnavailable")
        } else if list.canPost {
            HStack(alignment: .top) {
                TextField("Add a comment", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).accessibilityIdentifier("socialDraft")
                Button("Post") {
                    let text = draft
                    Task { if await surface.post(text, on: subject) == .confirmed { draft = "" } }
                }.musicAction(.secondary).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || surface.busy.contains(subject)).accessibilityIdentifier("socialPost")
            }
        } else {
            Text("YouTube Music didn’t offer commenting here.").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("socialCannotPost")
        }
    }
}
