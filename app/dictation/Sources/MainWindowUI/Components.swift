import DictationCore
import SwiftUI

/// "Everything stays on this Mac. Nothing is sent anywhere." with a lock.
struct PrivacyLine: View {
    var body: some View {
        Label(L10nKey.privacyLine.text, systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

/// A big symbol, a title and a line, centred: the empty and the switched-off states.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            actions().padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The status of a meeting: a spinner while work runs, else a coloured dot, and the plain words.
struct StatusLabel: View {
    let status: MeetingStatusLine

    var body: some View {
        HStack(spacing: 5) {
            if status.isBusy {
                if status == .recording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                } else {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
                }
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(status.titleKey.text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .transcriptOnly: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

/// A round badge with the speaker's initials, in a colour that stays with the speaker.
struct SpeakerAvatar: View {
    let name: String
    let index: Int
    var size: CGFloat = 28

    static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .green]

    static func color(_ index: Int) -> Color { palette[abs(index) % palette.count] }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(index).gradient, in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        let s = letters.joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// A key as a small cap: "⌃Space".
struct KeyCap: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.title3, design: .rounded).weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
    }
}

/// A Form row that says what it is on the left and what it holds on the right, with a hint line under the title.
struct HintedRow<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}
