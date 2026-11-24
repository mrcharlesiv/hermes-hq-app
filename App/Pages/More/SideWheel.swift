import SwiftUI
import UIKit

/// [macpass-tools] Feel list D32 (2026-11-13): a strip that scrolls only sideways (the Files trail, the Terminal's tabs,
/// the Screen's control strip) didn't move under a plain mouse's wheel, which only turns up and down: a long trail's
/// first folders, a ninth tab, the strip's last buttons were out of reach without a trackpad. On the Mac the wheel now
/// turns such a strip sideways, as AppKit's own side-scrolling views do. A trackpad's sideways swipe keeps working as
/// before (the scroll view's own pan takes it); the iPhone and iPad are unchanged.
@MainActor enum SideWheel {
    static func install(on scroll: UIScrollView) {
        #if targetEnvironment(macCatalyst)
        guard !scroll.gestureRecognizers.orEmpty.contains(where: { $0 is SideWheelRecognizer }) else { return }
        let wheel = SideWheelRecognizer(scroll: scroll)
        scroll.addGestureRecognizer(wheel)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private final class SideWheelRecognizer: UIPanGestureRecognizer {
    private weak var scroll: UIScrollView?
    private var last: CGPoint = .zero

    init(scroll: UIScrollView) {
        self.scroll = scroll
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(turned))
        allowedTouchTypes = []                  // the wheel only, never a click or a drag
        allowedScrollTypesMask = .discrete      // a mouse's wheel; a trackpad already scrolls the strip sideways
    }

    @objc private func turned() {
        guard let scroll else { return }
        switch state {
        case .began:
            last = .zero
        case .changed:
            let now = translation(in: scroll)
            let moved = now.y - last.y
            last = now
            let most = max(0, scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width)
            let least = -scroll.adjustedContentInset.left
            guard most > least else { return }
            let x = min(max(scroll.contentOffset.x - moved, least), most)
            scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: false)
        default:
            break
        }
    }
}

private extension Optional where Wrapped == [UIGestureRecognizer] {
    var orEmpty: [UIGestureRecognizer] { self ?? [] }
}
#endif

extension View {
    /// Installs `SideWheel` on the nearest enclosing horizontal `UIScrollView` (no-op off Mac).
    func hqSideWheel() -> some View {
        #if targetEnvironment(macCatalyst)
        background(SideWheelBridge())
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct SideWheelBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.attach() }

    final class Probe: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            var cur = superview
            while let view = cur {
                if let scroll = view as? UIScrollView { SideWheel.install(on: scroll); return }
                cur = view.superview
            }
        }
    }
}
#endif
