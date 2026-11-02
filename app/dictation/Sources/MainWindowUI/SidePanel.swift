import DictationCore
import SwiftUI

/// A trailing column that opens and closes beside the page: the macOS-13-safe stand-in for
/// `.inspector` (macOS 14). Its slide goes through MotionPolicy, so Reduce Motion snaps it instead.
public struct SidePanel<Content: View>: View {
    @Binding var isOpen: Bool
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isOpen: Binding<Bool>, width: CGFloat = 280, @ViewBuilder content: @escaping () -> Content) {
        _isOpen = isOpen
        self.width = width
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isOpen {
                Divider()
                content()
                    .frame(width: width)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: MotionPolicy.animationSeconds(0.2, reduceMotion: reduceMotion)), value: isOpen)
    }
}
