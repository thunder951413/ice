//
//  GeneralSettingsPane.swift
//  Ice
//

import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var loginItemManager = LoginItemManager()
    @State private var isImportingCustomIceIcon = false
    @State private var isPresentingError = false
    @State private var presentedError: LocalizedErrorWrapper?
    @State private var isApplyingOffset = false
    @State private var tempItemSpacingOffset: CGFloat = 0 // Temporary state for the slider
    @State private var isConfirmingLayoutReset = false

    private var manager: GeneralSettingsManager {
        appState.settingsManager.generalSettingsManager
    }

    private var itemSpacingOffset: LocalizedStringKey {
        localizedOffsetString(for: manager.itemSpacingOffset)
    }

    private func localizedOffsetString(for offset: CGFloat) -> LocalizedStringKey {
        switch offset {
        case -16:
            return LocalizedStringKey("none")
        case 0:
            return LocalizedStringKey("default")
        case 16:
            return LocalizedStringKey("max")
        default:
            return LocalizedStringKey(offset.formatted())
        }
    }

    private var rehideIntervalKey: LocalizedStringKey {
        let formatted = manager.rehideInterval.formatted()
        if manager.rehideInterval == 1 {
            return LocalizedStringKey(formatted + " second")
        } else {
            return LocalizedStringKey(formatted + " seconds")
        }
    }

    private var hasSpacingSliderValueChanged: Bool {
        tempItemSpacingOffset != manager.itemSpacingOffset
    }

    private var isActualOffsetDifferentFromDefault: Bool {
        manager.itemSpacingOffset != 0
    }

    var body: some View {
        IceForm {
            IceSection {
                launchAtLogin
            }
            IceSection {
                iceIconOptions
            }
            IceSection {
                iceBarOptions
            }
            IceSection {
                Toggle("Enable menu bar search", isOn: manager.bindings.enableMenuBarSearch)
                    .annotation("Search menu bar icons only. Turning this off hides search commands and disables its shortcut.")
            }
            IceSection {
                showOnClick
                showOnHover
                showOnScroll
            }
            IceSection {
                autoRehideOptions
            }
            IceSection {
                spacingOptions
            }
            IceSection {
                recoverOptions
            }
        }
        .alert(isPresented: $isPresentingError, error: presentedError) {
            Button("OK") {
                presentedError = nil
                isPresentingError = false
            }
        }
        .confirmationDialog(
            "Reset menu bar layout?",
            isPresented: $isConfirmingLayoutReset,
            titleVisibility: .visible
        ) {
            Button("Reset Menu Bar Layout", role: .destructive) {
                appState.menuBarManager.resetModifications()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This reveals all items, restores default spacing, and clears Ice's saved item arrangement.")
        }
    }

    @ViewBuilder
    private var launchAtLogin: some View {
        Toggle(
            "Launch at login",
            isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { loginItemManager.setEnabled($0) }
            )
        )
        .annotation {
            VStack(alignment: .leading, spacing: 6) {
                switch loginItemManager.status {
                case .requiresApproval:
                    Text("Allow Ice in System Settings to finish enabling launch at login.")
                    Button("Open Login Item Settings") {
                        loginItemManager.openSystemSettings()
                    }
                case .notFound:
                    Text("Ice could not find its login item registration. Move Ice to Applications and try again.")
                case .enabled, .notRegistered:
                    EmptyView()
                }

                if let errorMessage = loginItemManager.errorMessage {
                    Text(errorMessage)
                }
            }
        }
        .onAppear {
            loginItemManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemManager.refresh()
        }
    }

    @ViewBuilder
    private func menuItem(for imageSet: ControlItemImageSet) -> some View {
        Label {
            Text(imageSet.name.rawValue)
        } icon: {
            if let nsImage = imageSet.hidden.nsImage(for: appState) {
                switch imageSet.name {
                case .custom:
                    Image(size: CGSize(width: 18, height: 18)) { context in
                        context.draw(
                            Image(nsImage: nsImage),
                            in: context.clipBoundingRect
                        )
                    }
                default:
                    Image(nsImage: nsImage)
                }
            }
        }
    }

    @ViewBuilder
    private var iceIconOptions: some View {
        Toggle("Show Ice icon", isOn: manager.bindings.showIceIcon)
            .annotation {
                if !manager.showIceIcon {
                    Text("You can still access Ice's settings by right-clicking an empty area in the menu bar")
                }
            }
        if manager.showIceIcon {
            IceMenu("Ice icon") {
                Picker("Ice icon", selection: manager.bindings.iceIcon) {
                    ForEach(ControlItemImageSet.userSelectableIceIcons) { imageSet in
                        Button {
                            manager.iceIcon = imageSet
                        } label: {
                            menuItem(for: imageSet)
                        }
                        .tag(imageSet)
                    }
                    if let lastCustomIceIcon = manager.lastCustomIceIcon {
                        Button {
                            manager.iceIcon = lastCustomIceIcon
                        } label: {
                            menuItem(for: lastCustomIceIcon)
                        }
                        .tag(lastCustomIceIcon)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button("Choose image…") {
                    isImportingCustomIceIcon = true
                }
            } title: {
                menuItem(for: manager.iceIcon)
            }
            .annotation("Choose a custom icon to show in the menu bar")
            .fileImporter(
                isPresented: $isImportingCustomIceIcon,
                allowedContentTypes: [.image]
            ) { result in
                do {
                    let url = try result.get()
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        let data = try Data(contentsOf: url)
                        manager.iceIcon = ControlItemImageSet(name: .custom, image: .data(data))
                    }
                } catch {
                    presentedError = LocalizedErrorWrapper(error)
                    isPresentingError = true
                }
            }

            if case .custom = manager.iceIcon.name {
                Toggle("Apply system theme to icon", isOn: manager.bindings.customIceIconIsTemplate)
                    .annotation("Display the icon as a monochrome image matching the system appearance")
            }
        }
    }

    @ViewBuilder
    private var iceBarOptions: some View {
        useIceBar
        if manager.useIceBar {
            iceBarLocationPicker
            iceBarStylePicker
            iceBarSizingOptions
            showIceBarButton
        }
    }

    @ViewBuilder
    private var useIceBar: some View {
        Toggle("Use Ice Bar", isOn: manager.bindings.useIceBar)
            .annotation("Show hidden menu bar items in a separate bar below the menu bar")
    }

    @ViewBuilder
    private var iceBarLocationPicker: some View {
        IcePicker("Location", selection: manager.bindings.iceBarLocation) {
            ForEach(IceBarLocation.allCases) { location in
                Text(location.localized).tag(location)
            }
        }
        .annotation {
            switch manager.iceBarLocation {
            case .dynamic:
                Text("The Ice Bar's location changes based on context")
            case .mousePointer:
                Text("The Ice Bar is centered below the mouse pointer")
            case .iceIcon:
                Text("The Ice Bar is centered below the Ice icon")
            }
        }
    }

    @ViewBuilder
    private var iceBarStylePicker: some View {
        IcePicker("Appearance", selection: manager.bindings.iceBarStyle) {
            ForEach(IceBarStyle.allCases) { style in
                Text(style.localized).tag(style)
            }
        }
        .annotation("The Ice Bar's appearance is independent of the menu bar background")
    }

    @ViewBuilder
    private var iceBarSizingOptions: some View {
        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarIconSize, in: 16...36, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Icon size")
                Text("\(manager.iceBarIconSize.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("Icon size")
        }

        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarItemSpacing, in: 0...12, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Icon spacing")
                Text("\(manager.iceBarItemSpacing.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("Icon spacing")
        }

        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarPadding, in: 2...12, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Background padding")
                Text("\(manager.iceBarPadding.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("Background padding")
        }

        Button("Reset sizes") {
            manager.iceBarIconSize = 28
            manager.iceBarItemSpacing = 2
            manager.iceBarPadding = 4
        }
        .annotation("Adjust the Ice Bar's icon and background dimensions")
    }

    @ViewBuilder
    private var showIceBarButton: some View {
        Button("Show Ice Bar") {
            appState.menuBarManager.section(withName: .hidden)?.show()
        }
    }

    @ViewBuilder
    private var showOnClick: some View {
        Toggle("Show on click", isOn: manager.bindings.showOnClick)
            .annotation("Click inside an empty area of the menu bar to show hidden menu bar items")
    }

    @ViewBuilder
    private var showOnHover: some View {
        Toggle("Show on hover", isOn: manager.bindings.showOnHover)
            .annotation("Hover over an empty area of the menu bar to show hidden menu bar items")
    }

    @ViewBuilder
    private var showOnScroll: some View {
        Toggle("Show on scroll", isOn: manager.bindings.showOnScroll)
            .annotation("Scroll or swipe in the menu bar to toggle hidden menu bar items")
    }

    @ViewBuilder
    private var spacingOptions: some View {
        IceLabeledContent {
            IceSlider(
                localizedOffsetString(for: tempItemSpacingOffset),
                value: $tempItemSpacingOffset,
                in: -16...16,
                step: 2
            )
            .disabled(isApplyingOffset)
        } label: {
            IceLabeledContent {
                Button("Apply") {
                    applyOffset()
                }
                .help("Apply the current spacing")
                .disabled(isApplyingOffset || !hasSpacingSliderValueChanged)

                if isApplyingOffset {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 15, height: 15)
                } else {
                    Button {
                        resetOffsetToDefault()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the default spacing")
                    .disabled(isApplyingOffset || !isActualOffsetDifferentFromDefault)
                }
            } label: {
                HStack {
                    Text("Menu bar item spacing")
                    BetaBadge()
                }
            }
        }
        .annotation(
            "Applying this setting will relaunch all apps with menu bar items. Some apps may need to be manually relaunched.",
            spacing: 2
        )
        .annotation(spacing: 10, font: .callout.bold()) {
            IceGroupBox {
                Label {
                    Text("Note: You may need to log out and back in for this setting to apply properly.")
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            tempItemSpacingOffset = manager.itemSpacingOffset
        }
    }

    @ViewBuilder
    private var recoverOptions: some View {
        HStack(alignment: .top) {
            Text("Menu bar recovery")
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            VStack(alignment: .trailing, spacing: 8) {
                Button(appState.menuBarManager.isHidingPaused ? "Resume Hiding Menu Bar Items" : "Pause Hiding Menu Bar Items") {
                    appState.menuBarManager.toggleHidingPaused()
                }
                .accessibilityLabel(appState.menuBarManager.isHidingPaused ? "Resume hiding menu bar items" : "Pause hiding menu bar items")
                .accessibilityHint(appState.menuBarManager.isHidingPaused
                    ? "Restores the menu bar hiding state from before the pause"
                    : "Temporarily reveals items without changing the saved menu bar layout")

                Button("Reset Menu Bar Layout…", role: .destructive) {
                    isConfirmingLayoutReset = true
                }
                .accessibilityLabel("Reset menu bar layout")
                .accessibilityHint("Opens a confirmation before resetting the saved layout and spacing")
            }
            .layoutPriority(1)
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .annotation(
            "Pause hiding temporarily to recover items, or reset the saved layout and spacing if items remain inaccessible."
        )
    }

    @ViewBuilder
    private var rehideStrategyPicker: some View {
        IcePicker("Strategy", selection: manager.bindings.rehideStrategy) {
            ForEach(RehideStrategy.allCases) { strategy in
                Text(strategy.localized).tag(strategy)
            }
        }
        .annotation {
            switch manager.rehideStrategy {
            case .smart:
                Text("Menu bar items are rehidden using a smart algorithm")
            case .timed:
                Text("Menu bar items are rehidden after a fixed amount of time")
            case .focusedApp:
                Text("Menu bar items are rehidden when the focused app changes")
            }
        }
    }

    @ViewBuilder
    private var autoRehideOptions: some View {
        Toggle("Automatically rehide", isOn: manager.bindings.autoRehide)
        if manager.autoRehide {
            if case .timed = manager.rehideStrategy {
                VStack {
                    rehideStrategyPicker
                    IceSlider(
                        rehideIntervalKey,
                        value: manager.bindings.rehideInterval,
                        in: 0...30,
                        step: 1
                    )
                }
            } else {
                rehideStrategyPicker
            }
        }
    }

    /// Apply menu bar spacing offset.
    private func applyOffset() {
        isApplyingOffset = true
        manager.itemSpacingOffset = tempItemSpacingOffset
        Task {
            do {
                try await appState.spacingManager.applyOffset()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            isApplyingOffset = false
        }
    }

    /// Reset menu bar spacing offset to default.
    private func resetOffsetToDefault() {
        tempItemSpacingOffset = 0
        manager.itemSpacingOffset = tempItemSpacingOffset
        applyOffset()
    }
}
