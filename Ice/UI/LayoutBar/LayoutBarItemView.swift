//
//  LayoutBarItemView.swift
//  Ice
//

import Cocoa
import Combine

// MARK: - LayoutBarItemView

/// A view that displays an image in a menu bar layout view.
final class LayoutBarItemView: NSView {
    private weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    /// The item that the view represents.
    let item: MenuBarItem

    /// Temporary information that the item view retains when it is moved outside
    /// of a layout view.
    ///
    /// When the item view is dragged outside of a layout view, this property is set
    /// to hold the layout view's container view, as well as the index of the item
    /// view in relation to the container's other items. Upon being inserted into a
    /// new layout view, these values are removed. If the item is dropped outside of
    /// a layout view, these values are used to reinsert the item view in its original
    /// layout view.
    var oldContainerInfo: (container: LayoutBarContainer, index: Int)?

    /// A Boolean value that indicates whether the item view is currently inside a container.
    var hasContainer = false

    /// The image displayed inside the view.
    private var image: NSImage? {
        didSet {
            if
                let image,
                let screen = appState?.imageCache.screen
            {
                let size = CGSize(
                    width: image.size.width / screen.backingScaleFactor,
                    height: image.size.height / screen.backingScaleFactor
                )
                setFrameSize(size)
            } else {
                setFrameSize(Self.fallbackSize(for: item))
            }
            needsDisplay = true
        }
    }

    /// A hosted accessibility element can briefly report a zero-sized frame while
    /// its owning menu bar is updating. Keep a tangible placeholder in that case:
    /// otherwise every item can collapse the layout bar's height to zero before an
    /// image capture arrives.
    private static func fallbackSize(for item: MenuBarItem) -> CGSize {
        CGSize(
            width: max(40, item.frame.width),
            height: max(20, item.frame.height)
        )
    }

    /// A Boolean value that indicates whether the item view is a dragging placeholder.
    ///
    /// If this value is `true`, the item view does not draw its image.
    var isDraggingPlaceholder = false {
        didSet {
            needsDisplay = true
        }
    }

    /// A Boolean value that indicates whether the view is enabled.
    var isEnabled = true {
        didSet {
            needsDisplay = true
        }
    }

    /// Creates a view that displays the given menu bar item.
    init(appState: AppState, item: MenuBarItem) {
        self.item = item
        self.appState = appState

        // Start with a nonzero frame. Hosted accessibility items may not have a
        // live frame at this exact moment, and a zero-height child collapses the
        // entire manually laid-out container.
        super.init(frame: CGRect(origin: .zero, size: Self.fallbackSize(for: item)))
        unregisterDraggedTypes()

        self.toolTip = item.displayName
        self.isEnabled = item.isMovable

        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            appState.imageCache.$images
                .sink { [weak self] images in
                    guard
                        let self,
                        let cgImage = images[item.stableID]
                    else {
                        return
                    }
                    let scale = appState.imageCache.screen?.backingScaleFactor ?? 2
                    guard CGFloat(cgImage.width) <= max(200, item.frame.width * scale * 2) else {
                        image = nil
                        return
                    }
                    image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Provides an alert to display when the item view is disabled.
    func provideAlertForDisabledItem() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Menu bar item is not movable."
        alert.informativeText = "macOS prohibits \"\(item.displayName)\" from being moved."
        return alert
    }

    /// Provides an alert to display when a menu bar item is unresponsive.
    func provideAlertForUnresponsiveItem() -> NSAlert {
        let alert = provideAlertForDisabledItem()
        alert.informativeText = "\(item.displayName) is unresponsive. Until it is restarted, it cannot be moved. Movement of other menu bar items may also be affected until this is resolved."
        return alert
    }

    override func draw(_ dirtyRect: NSRect) {
        if !isDraggingPlaceholder {
            if let image {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = .zero
                shadow.set()
                image.draw(
                    in: bounds,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: isEnabled ? 1.0 : 0.67
                )
                NSGraphicsContext.restoreGraphicsState()
            } else if item.hostedHandle != nil, let icon = item.owningApplication?.icon {
                let side = min(20, bounds.height)
                icon.draw(in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
            } else {
                let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
                NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.16 : 0.08).setFill()
                background.fill()
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(isEnabled ? 1 : 0.67),
                    .paragraphStyle: paragraphStyle,
                ]
                NSString(string: item.displayName).draw(
                    in: bounds.insetBy(dx: 4, dy: max(2, (bounds.height - 14) / 2)),
                    withAttributes: attributes
                )
            }
            if Bridging.responsivity(for: item.ownerPID) == .unresponsive {
                let warningImage = NSImage.warning
                let width: CGFloat = 15
                let scale = width / warningImage.size.width
                let size = CGSize(
                    width: width,
                    height: warningImage.size.height * scale
                )
                warningImage.draw(
                    in: CGRect(
                        x: bounds.maxX - size.width,
                        y: bounds.minY,
                        width: size.width,
                        height: size.height
                    )
                )
            }
        }
    }

    private func sectionMenu() -> NSMenu? {
        guard HostedItemVisibilityManager.isSupported, item.canBeHidden, let appState else {
            return nil
        }
        let menu = NSMenu()
        for (index, name) in MenuBarSection.Name.allCases.enumerated() {
            guard appState.menuBarManager.section(withName: name)?.isEnabled == true else { continue }
            let entry = NSMenuItem(title: "Move to \(name.displayString)", action: #selector(moveToSection(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = appState.itemManager.itemCache[name].contains(where: { $0.stableID == item.stableID }) ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        sectionMenu() ?? super.menu(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let menu = sectionMenu() else {
            super.mouseUp(with: event)
            return
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func moveToSection(_ sender: NSMenuItem) {
        let sections = MenuBarSection.Name.allCases
        guard sections.indices.contains(sender.tag) else { return }
        appState?.itemManager.assignHostedItem(item, to: sections[sender.tag])
    }

    override func mouseDragged(with event: NSEvent) {
        // macOS 27 does not deliver layout-bar drops reliably. Selecting a
        // section is handled by the click menu instead.
        guard !HostedItemVisibilityManager.isSupported else {
            return
        }
        super.mouseDragged(with: event)

        guard isEnabled else {
            let alert = provideAlertForDisabledItem()
            alert.runModal()
            return
        }

        guard Bridging.responsivity(for: item.ownerPID) != .unresponsive else {
            let alert = provideAlertForUnresponsiveItem()
            alert.runModal()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        // contents of the pasteboard item don't matter here, as all needed information
        // is available directly from the dragging session; what matters is that the type
        // is set to `layoutBarItem`, as that is what the layout bar registers for
        pasteboardItem.setData(Data(), forType: .layoutBarItem)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: image)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

// MARK: LayoutBarItemView: NSDraggingSource
extension LayoutBarItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // make sure the container doesn't update its arranged views and that items
        // aren't arranged during a dragging session
        if let container = superview as? LayoutBarContainer {
            container.canSetArrangedViews = false
        }

        // prevent the dragging image from animating back to its original location
        session.animatesToStartingPositionsOnCancelOrFail = false

        // async to prevent the view from disappearing before the dragging image appears
        DispatchQueue.main.async {
            self.isDraggingPlaceholder = true
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            // always remove container info at the end of a session
            oldContainerInfo = nil
        }

        // since the session's `animatesToStartingPositionsOnCancelOrFail` property was
        // set to false when the session began (above), there is no delay between the user
        // releasing the dragging item and this method being called; thus, `isDraggingPlaceholder`
        // only needs to be updated here; if we ever decide we want animation, it may also
        // need to be updated inside `performDragOperation(_:)` on `LayoutBarPaddingView`
        isDraggingPlaceholder = false

        // if the drop occurs outside of a container, reinsert the view into its original
        // container at its original index
        if !hasContainer {
            guard let (container, index) = oldContainerInfo else {
                return
            }
            container.shouldAnimateNextLayoutPass = false
            container.arrangedViews.insert(self, at: index)
        }
    }
}

extension LayoutBarItemView: NSAccessibilityLayoutItem { }

extension LayoutBarItemView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        item.displayName
    }

    override func accessibilityIdentifier() -> String {
        "layout-bar-item.\(item.stableID)"
    }

    override func accessibilityPerformPress() -> Bool {
        guard let menu = sectionMenu() else {
            return super.accessibilityPerformPress()
        }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }
}

// MARK: Layout Bar Item Pasteboard Type
extension NSPasteboard.PasteboardType {
    static let layoutBarItem = Self("\(Constants.bundleIdentifier).layout-bar-item")
}
