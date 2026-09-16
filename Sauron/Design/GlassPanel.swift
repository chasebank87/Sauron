import AppKit
import QuartzCore
import SwiftUI

enum PanelPlacement: Sendable {
    case topCenter
    case trailing
    case leading
    case center
}

private final class SauronPanel: NSPanel {
    var allowsKey: Bool = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// `isMovableByWindowBackground` alone doesn't work here: it only fires when a mouseDown
/// reaches the window's background view unhandled, but SwiftUI's own hit-testing routes a
/// click to whichever internal SwiftUI-bridging subview geometrically contains the point --
/// for empty/background areas that's this root hosting view itself, and its default
/// `mouseDown` never forwards to the window. Forwarding it to `performDrag` here restores
/// dragging for exactly those background clicks; clicks that land on a real button/control
/// are hit-tested to a *different*, deeper subview and never reach this override at all, so
/// interactive content underneath keeps working normally.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class GlassPanelController {
    private var panel: NSPanel?
    private var glassView: NSGlassEffectView?
    private var hostingView: DraggableHostingView<AnyView>?

    func present<Content: View>(
        _ view: Content,
        size: CGSize,
        placement: PanelPlacement,
        activates: Bool = false,
        usesPaneChrome: Bool = true,
        animated: Bool = false,
        ordersFront: Bool = true
    ) {
        let hosted = AnyView(view.tint(SauronTheme.accent))
        let wantsNonactivating = !activates
        if let panel, panel.styleMask.contains(.nonactivatingPanel) != wantsNonactivating {
            close()
        }

        if let hostingView, let panel {
            hostingView.rootView = hosted
            layout(panel: panel, size: size, placement: placement)
            finishPresent(panel, activates: activates, animated: animated, ordersFront: ordersFront)
            return
        }

        let panel = SauronPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: activates
                ? [.borderless, .fullSizeContentView]
                : [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.allowsKey = activates
        panel.isFloatingPanel = true
        // Activated panels (onboarding) must stay at normal level so System Settings
        // and TCC prompts are not covered. Utility overlays can float.
        panel.level = activates ? .normal : .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Keep overlays out of meeting screen shares even if hide-on-share misses.
        panel.sharingType = .none
        panel.becomesKeyOnlyIfNeeded = !activates
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        // Inherit System Settings appearance (light/dark) — do not force dark.
        panel.appearance = nil

        let hosting = DraggableHostingView(rootView: hosted)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        if usesPaneChrome {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.style = .regular
            glass.cornerRadius = SauronTheme.cardRadius
            glass.contentView = hosting
            glass.autoresizingMask = [.width, .height]
            panel.contentView = glass
            self.glassView = glass
        } else {
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.frame = root.bounds
            root.addSubview(hosting)
            panel.contentView = root
        }

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        self.panel = panel
        self.hostingView = hosting
        layout(panel: panel, size: size, placement: placement)
        finishPresent(panel, activates: activates, animated: animated, ordersFront: ordersFront)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        glassView = nil
        hostingView = nil
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func reveal() {
        guard let panel else { return }
        panel.alphaValue = 1
        order(panel, activates: false)
    }

    var isVisible: Bool { panel?.isVisible == true }

    var isPresented: Bool { panel != nil }

    private func finishPresent(_ panel: NSPanel, activates: Bool, animated: Bool, ordersFront: Bool) {
        if animated, ordersFront {
            animateIn(panel, activates: activates)
            return
        }
        panel.alphaValue = 1
        if ordersFront {
            order(panel, activates: activates)
        } else {
            panel.orderOut(nil)
        }
    }

    private func animateIn(_ panel: NSPanel, activates: Bool) {
        let finalFrame = panel.frame
        var startFrame = finalFrame
        startFrame.origin.y += 18
        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0
        if let layer = panel.contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let mid = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            layer.position = mid
            layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        }
        order(panel, activates: activates)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.48
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        if let layer = panel.contentView?.layer {
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.9
            scale.toValue = 1
            scale.mass = 0.7
            scale.stiffness = 180
            scale.damping = 16
            scale.duration = scale.settlingDuration
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "promptPop")
            layer.transform = CATransform3DIdentity
        }
    }

    private func order(_ panel: NSPanel, activates: Bool) {
        if activates {
            panel.level = .normal
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func layout(panel: NSPanel, size: CGSize, placement: PanelPlacement) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin: NSPoint
        switch placement {
        case .topCenter:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 18
            )
        case .trailing:
            origin = NSPoint(
                x: visible.maxX - size.width - 22,
                y: visible.maxY - size.height - 56
            )
        case .leading:
            origin = NSPoint(
                x: visible.minX + 22,
                y: visible.maxY - size.height - 56
            )
        case .center:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        glassView?.frame = NSRect(origin: .zero, size: size)
        glassView?.cornerRadius = SauronTheme.cardRadius
        hostingView?.frame = NSRect(origin: .zero, size: size)
    }
}

enum GlassChrome {
    static let promptSize = CGSize(width: 480, height: 620)
    static let transcriptSize = CGSize(width: 400, height: 620)
    static let assistSize = CGSize(width: 340, height: 520)
    static let errorSize = CGSize(width: 380, height: 160)
    static let onboardingSize = CGSize(width: 440, height: 660)
}
