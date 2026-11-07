import DictationCore
import SwiftUI

/// The finished track's bars. The one custom drawing on Озвучка: a `Canvas` of rounded bars in the system's semantic
/// colours, with the part already played in the accent colour. It is static under Reduce Motion: nothing animates and the
/// playback cursor is not drawn at all, so the picture never moves; the clock beside it carries the position. Without
/// Reduce Motion the cursor sits where `playedFraction` says; the app moves that value only while audio plays and
/// resets it to 0 (no cursor) when the sound stops.
struct WaveformView: View {
    let peaks: [Float]
    let playedFraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let slot = size.width / CGFloat(peaks.count)
            let barWidth = max(1, slot * 0.6)
            let showCursor = playedFraction > 0 && !reduceMotion
            let cursorX = size.width * CGFloat(min(max(playedFraction, 0), 1))
            for (i, peak) in peaks.enumerated() {
                let x = slot * CGFloat(i) + (slot - barWidth) / 2
                let height = max(2, size.height * CGFloat(min(max(peak, 0), 1)))
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                let played = showCursor && x + barWidth / 2 <= cursorX
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(played ? Color.accentColor : Color.secondary.opacity(0.55)))
            }
            if showCursor {
                context.fill(Path(CGRect(x: min(cursorX, size.width - 1), y: 0, width: 1, height: size.height)),
                             with: .color(Color.primary))
            }
        }
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel(L10nKey.speakWaveform.text)
    }
}
