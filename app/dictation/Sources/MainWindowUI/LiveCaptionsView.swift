import DictationCore
import SwiftUI

/// What a meeting that is being recorded shows in place of its tabs: the conversation as it is spoken, a few seconds
/// behind, "You" for the microphone and "Others" for the call. A preview — the transcript and the notes made after the
/// recording replace it. The list follows the newest line until the user scrolls up; "Jump to Latest" brings it back.
struct LiveCaptionsView: View {
    let feed: LiveFeed
    /// The name the transcript will give the microphone channel (the user's own); "You" when none was read.
    let ownerName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the end of the list is on screen: the list follows new lines only then.
    @State private var atBottom = true
    /// A new line pushes the end of the list off screen for a moment before the scroll brings it back; that
    /// disappearance is the list growing, not the reader leaving, and must not stop the following.
    @State private var settling = false
    private let bottomID = "live-bottom"

    private var meName: String { ownerName.isEmpty ? L10nKey.meetingSpeakerYou.text : ownerName }
    private var themName: String { L10nKey.meetingLiveThem.text }

    var body: some View {
        VStack(spacing: 0) {
            if feed.captions.isEmpty {
                // With a notice to give, that is the answer: "Listening" would say the opposite.
                if LiveNotice.key(for: feed) == nil { waiting } else { Color.clear.frame(maxHeight: .infinity) }
            } else {
                list
            }
            footer
        }
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "captions.bubble").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L10nKey.meetingLiveWaiting.text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(feed.captions.enumerated()), id: \.element.id) { index, caption in
                        CaptionRow(caption: caption, name: caption.channel == .me ? meName : themName,
                                   avatarIndex: caption.channel == .me ? 0 : 1,
                                   showsHeader: index == 0 || feed.captions[index - 1].channel != caption.channel)
                            .id(caption.id)
                    }
                    // The end of the list: on screen means "the reader is at the newest line". A lazy stack reports a
                    // row leaving and entering the screen, which is all this needs (macOS 14 has no scroll-offset API).
                    Color.clear.frame(height: 1).id(bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { if !settling { atBottom = false } }
                }
                .padding(.vertical, 18).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: feed.captions.count) { old, new in
                guard new > old, atBottom else { return }
                settling = true
                scrollToBottom(proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settling = false }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Label(L10nKey.meetingLiveLatest.text, systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(bottomID, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let key = LiveNotice.key(for: feed) {
                // Only the icon is tinted: orange text on the bar is too faint to read.
                Label { Text(key.text).foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.callout)
            }
            Text(L10nKey.meetingLivePreview.text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One caption: the speaker and the time when the speaker changes, the words always.
private struct CaptionRow: View {
    let caption: LiveCaption
    let name: String
    let avatarIndex: Int
    let showsHeader: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsHeader {
                SpeakerAvatar(name: name, index: avatarIndex, size: 26)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsHeader {
                    HStack(spacing: 6) {
                        Text(name).fontWeight(.semibold)
                        Text(MeetingBadgeModel.clock(caption.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(caption.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.top, showsHeader ? 8 : 0).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Every row says who spoke, also a continuation row that shows no header. A `String`, not a literal: a name
        // is not a localization key.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(MeetingBadgeModel.clock(caption.start)). \(caption.text)")
    }
}
