import AppKit
import SwiftUI

@MainActor
final class MeetingBannerController {
    var onRecord: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?

    private let panel: NSPanel
    private var autoDismissTask: Task<Void, Never>?

    private static let bannerWidth: CGFloat = 300
    private static let screenInset: CGFloat = 14
    private static let autoDismissAfter: Duration = .seconds(15)
    private static let showAnimationDuration: CFTimeInterval = 0.22
    private static let hideAnimationDuration: CFTimeInterval = 0.18
    private static let slideOffset: CGFloat = 20

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.bannerWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionIfVisible() }
        }
    }

    // Owned by SwiftUI @State at the app root, so this never deinits in practice.
    // Skip teardown rather than fight the nonisolated-deinit rules.

    func show(appName: String) {
        let wasVisible = panel.isVisible

        let view = MeetingBannerView(
            appName: appName,
            onRecord: { [weak self] in
                self?.hide()
                self?.onRecord?()
            },
            onDismiss: { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.layoutIfNeeded()

        let target = targetFrame(for: hosting.fittingSize.height)

        if wasVisible {
            panel.setFrame(target, display: true, animate: false)
        } else {
            var start = target
            start.origin.y += Self.slideOffset
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.showAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }

        scheduleAutoDismiss()
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        guard panel.isVisible else { return }

        var end = panel.frame
        end.origin.y += Self.slideOffset

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.hideAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        })
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoDismissAfter)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func repositionIfVisible() {
        guard panel.isVisible else { return }
        let height = (panel.contentView as? NSHostingView<MeetingBannerView>)?
            .fittingSize.height ?? panel.frame.height
        panel.setFrame(targetFrame(for: height), display: true)
    }

    private func targetFrame(for contentHeight: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 100, y: 100, width: Self.bannerWidth, height: contentHeight)
        }
        let height = max(contentHeight, 56)
        let x = visible.maxX - Self.bannerWidth - Self.screenInset
        let y = visible.maxY - height - Self.screenInset
        return NSRect(x: x, y: y, width: Self.bannerWidth, height: height)
    }
}

private struct MeetingBannerView: View {
    let appName: String
    let onRecord: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        pill
            .overlay(alignment: .topLeading) { dismissButton }
            .padding(.top, 8)
            .padding(.leading, 8)
            .frame(width: 300, alignment: .leading)
            .preferredColorScheme(.dark)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting detected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.vertical, 14)

            Spacer(minLength: 10)

            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .controlSize(.regular)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
        }
        .glassEffect(in: .rect(cornerRadius: 18))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.65))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
        .offset(x: -6, y: -6)
    }
}
