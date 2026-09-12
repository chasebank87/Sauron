import AppKit
import SwiftUI

/// Finds the enclosing `NSScrollView` and applies a quiet overlay scroller.
struct LiquidGlassScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onMoveToWindow = { [weak view] in
            guard let view else { return }
            Self.configureScroller(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configureScroller(from: nsView)
    }

    private static func configureScroller(from view: NSView) {
        guard let scroll = enclosingScrollView(from: view) else { return }
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .default

        if scroll.verticalScroller == nil || !(scroll.verticalScroller is SubtleOverlayScroller) {
            let scroller = SubtleOverlayScroller()
            scroller.controlSize = .small
            scroller.scrollerStyle = .overlay
            scroller.knobStyle = .default
            scroll.verticalScroller = scroller
        }

        scroll.verticalScroller?.controlSize = .small
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.verticalScroller?.alphaValue = 0.55
        scroll.appearance = nil
        scroll.verticalScroller?.appearance = nil
    }

    private static func enclosingScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view.superview
        while let node = current {
            if let scroll = node as? NSScrollView { return scroll }
            current = node.superview
        }
        return nil
    }

    private final class ProbeView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }
}

/// Narrow, low-contrast overlay knob — visible while scrolling, otherwise out of the way.
private final class SubtleOverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track / slot fill — keeps the gutter invisible.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }

        let inset = knob.insetBy(dx: knob.width * 0.32, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width / 2, yRadius: inset.width / 2)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.28)
        color.setFill()
        path.fill()
    }
}

extension View {
    /// Quiet overlay scroller — thin, translucent, auto-hiding.
    func observerLiquidGlassScroll() -> some View {
        self
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background(LiquidGlassScrollChrome())
    }
}
