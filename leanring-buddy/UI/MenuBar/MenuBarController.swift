//
//  MenuBarController.swift
//  Sage
//
//  The leaf icon in the menu bar and the menu that drops down from it.
//
//  This is a standard macOS menu (NSMenu), not a custom panel, so it looks
//  and behaves exactly like other menu bar apps: system font, translucent
//  background, and automatic light and dark mode. The menu is rebuilt every
//  time it opens, so it always reflects Sage's current state.
//

import AppKit

extension Notification.Name {
    /// Posted by anything that wants the menu closed (for example when the
    /// push-to-talk shortcut is pressed while the menu is open).
    static let sageDismissMenu = Notification.Name("sageDismissMenu")
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let sessionCoordinator: SageSessionCoordinator
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()
    private var dismissMenuObserver: NSObjectProtocol?

    init(sessionCoordinator: SageSessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let leafIcon = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Sage")
        // Template images adapt to light and dark menu bars automatically.
        leafIcon?.isTemplate = true
        statusItem.button?.image = leafIcon

        // Items are enabled or disabled explicitly as the menu is built.
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        dismissMenuObserver = NotificationCenter.default.addObserver(
            forName: .sageDismissMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusMenu.cancelTracking()
            }
        }
    }

    /// Opens the menu shortly after launch so first-time users immediately
    /// see what's left to set up, instead of a silent icon.
    func showMenuOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems()
    }

    // MARK: - Building The Menu

    private var permissions: PermissionsCoordinator { sessionCoordinator.permissions }

    private var isFullySetUp: Bool {
        AppConfiguration.isConfigured
            && permissions.allPermissionsGranted
            && sessionCoordinator.hasCompletedOnboarding
    }

    private func rebuildMenuItems() {
        // Refresh first so permission rows reflect anything just changed in System Settings.
        permissions.refreshAllPermissions()
        statusMenu.removeAllItems()

        addStatusHeader()
        addAccessAndShortcutItems()
        statusMenu.addItem(.separator())

        if isFullySetUp {
            addReadyItems()
        } else {
            addSetupItems()
        }

        if let dictationErrorMessage = sessionCoordinator.dictationManager.lastErrorMessage {
            statusMenu.addItem(.separator())
            addInformationItem(dictationErrorMessage, symbolName: "exclamationmark.triangle")
        }

        statusMenu.addItem(.separator())
        addActionItem("About Sage", action: #selector(showAboutPanel))
        addActionItem("Quit Sage", action: #selector(quitSage), keyEquivalent: "q")
    }

    /// The greyed-out first line with a colored dot, like "Docker Desktop is running".
    private func addStatusHeader() {
        let statusTitle: String
        let statusDotColor: NSColor

        if !isFullySetUp {
            statusTitle = "Sage needs setup"
            statusDotColor = .systemOrange
        } else if sessionCoordinator.isFollowingAlong {
            statusTitle = "Sage is following along"
            statusDotColor = .systemGreen
        } else {
            switch sessionCoordinator.voiceState {
            case .idle:
                statusTitle = "Sage is ready"
                statusDotColor = .systemGreen
            case .listening:
                statusTitle = "Sage is listening"
                statusDotColor = .systemBlue
            case .processing:
                statusTitle = "Sage is thinking"
                statusDotColor = .systemBlue
            case .responding:
                statusTitle = "Sage is talking"
                statusDotColor = .systemBlue
            }
        }

        let statusLineItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLineItem.image = Self.statusDotImage(color: statusDotColor)
        statusLineItem.isEnabled = false
        statusMenu.addItem(statusLineItem)
    }

    private func addAccessAndShortcutItems() {
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.image = Self.symbolImage("keyboard")
        let shortcutMenu = NSMenu()
        for shortcut in PushToTalkShortcut.allCases {
            let item = NSMenuItem(title: shortcut.displayText, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut.rawValue
            item.state = PushToTalkShortcut.selected == shortcut ? .on : .off
            shortcutMenu.addItem(item)
        }
        shortcutItem.submenu = shortcutMenu
        statusMenu.addItem(shortcutItem)
        addActionItem("Enter Access Token…", symbolName: "key", action: #selector(enterAccessToken))
        if AccessTokenStore.token != nil {
            addActionItem("Remove Access Token", action: #selector(removeAccessToken))
        }
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let shortcut = PushToTalkShortcut(rawValue: rawValue) else { return }
        sessionCoordinator.selectShortcut(shortcut)
    }

    @objc private func enterAccessToken() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sage access token"
        alert.informativeText = "Enter your individual beta access token. It is stored in this Mac’s Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AccessTokenStore.save(field.stringValue)
            sessionCoordinator.accessCredentialsDidChange()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn’t save access token"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    @objc private func removeAccessToken() {
        do {
            try AccessTokenStore.remove()
            sessionCoordinator.accessCredentialsDidChange()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn’t remove access token"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    private func addReadyItems() {
        addInformationItem("Hold \(GlobalPushToTalkShortcutMonitor.shortcutDisplayText) to ask anything", symbolName: "keyboard")
        statusMenu.addItem(.separator())

        // Voice ▸ Mac / ElevenLabs
        let voiceMenuItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceMenuItem.image = Self.symbolImage("waveform")
        let voiceSubmenu = NSMenu()
        voiceSubmenu.autoenablesItems = false
        for voiceOption in SageVoiceOption.allCases {
            let voiceOptionItem = NSMenuItem(title: voiceOption.displayName, action: #selector(selectVoice(_:)), keyEquivalent: "")
            voiceOptionItem.target = self
            voiceOptionItem.representedObject = voiceOption.rawValue
            voiceOptionItem.state = sessionCoordinator.selectedVoice == voiceOption ? .on : .off
            voiceSubmenu.addItem(voiceOptionItem)
        }
        voiceMenuItem.submenu = voiceSubmenu
        statusMenu.addItem(voiceMenuItem)

        let soundsItem = addActionItem("Sounds", symbolName: "speaker.wave.2", action: #selector(toggleSoundEffects))
        soundsItem.state = sessionCoordinator.areSoundEffectsEnabled ? .on : .off

        statusMenu.addItem(.separator())
        addActionItem("Replay Intro", symbolName: "play.circle", action: #selector(replayIntro))
    }

    private func addSetupItems() {
        if !AppConfiguration.isConfigured {
            addInformationItem("Server or access token missing (see README)", symbolName: "exclamationmark.triangle")
            statusMenu.addItem(.separator())
        }

        statusMenu.addItem(.sectionHeader(title: "Permissions"))

        addPermissionItem(
            grantedTitle: "Microphone",
            requestTitle: "Allow Microphone…",
            symbolName: "mic",
            isGranted: permissions.hasMicrophonePermission,
            action: #selector(requestMicrophone)
        )
        addPermissionItem(
            grantedTitle: "Speech Recognition",
            requestTitle: "Allow Speech Recognition…",
            symbolName: "waveform",
            isGranted: permissions.hasSpeechRecognitionPermission,
            action: #selector(requestSpeechRecognition)
        )
        addPermissionItem(
            grantedTitle: "Accessibility",
            requestTitle: "Allow Accessibility…",
            symbolName: "hand.raised",
            isGranted: permissions.hasAccessibilityPermission,
            action: #selector(requestAccessibility)
        )
        if !permissions.hasAccessibilityPermission {
            // Dev builds sometimes don't appear in the list on their own.
            addActionItem("Show Sage in Finder", action: #selector(revealSageInFinder)).indentationLevel = 1
        }
        addPermissionItem(
            grantedTitle: "Screen Recording",
            requestTitle: "Allow Screen Recording…",
            symbolName: "rectangle.dashed.badge.record",
            isGranted: permissions.hasScreenRecordingPermission,
            action: #selector(requestScreenRecording)
        )
        if !permissions.hasScreenRecordingPermission {
            addInformationItem("Quit and reopen Sage after allowing", symbolName: nil).indentationLevel = 1
        } else {
            addPermissionItem(
                grantedTitle: "Screen Content",
                requestTitle: "Allow Screen Content…",
                symbolName: "eye",
                isGranted: permissions.hasScreenContentPermission,
                action: #selector(requestScreenContent)
            )
        }

        if permissions.allPermissionsGranted && !sessionCoordinator.hasCompletedOnboarding {
            statusMenu.addItem(.separator())
            let startItem = addActionItem("Start Sage", symbolName: "sparkles", action: #selector(startSage))
            startItem.isEnabled = AppConfiguration.isConfigured
        }

        statusMenu.addItem(.separator())
        addInformationItem("Sage captures screens when you ask and during follow-along.", symbolName: "lock")
    }

    // MARK: - Item Helpers

    /// A granted permission shows as a greyed-out row with a checkmark; a
    /// missing one is a clickable "Allow …" row.
    private func addPermissionItem(grantedTitle: String, requestTitle: String, symbolName: String, isGranted: Bool, action: Selector) {
        if isGranted {
            let grantedItem = NSMenuItem(title: grantedTitle, action: nil, keyEquivalent: "")
            grantedItem.image = Self.symbolImage(symbolName)
            grantedItem.state = .on
            grantedItem.isEnabled = false
            statusMenu.addItem(grantedItem)
        } else {
            addActionItem(requestTitle, symbolName: symbolName, action: action)
        }
    }

    @discardableResult
    private func addActionItem(_ title: String, symbolName: String? = nil, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let actionItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        actionItem.target = self
        actionItem.image = symbolName.flatMap(Self.symbolImage)
        statusMenu.addItem(actionItem)
        return actionItem
    }

    @discardableResult
    private func addInformationItem(_ title: String, symbolName: String?) -> NSMenuItem {
        let informationItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        informationItem.image = symbolName.flatMap(Self.symbolImage)
        informationItem.isEnabled = false
        statusMenu.addItem(informationItem)
        return informationItem
    }

    private static func symbolImage(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// A small filled circle in the given color, for the status line.
    private static func statusDotImage(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { drawingRect in
            color.setFill()
            NSBezierPath(ovalIn: drawingRect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: - Actions

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let voiceRawValue = sender.representedObject as? String,
              let voiceOption = SageVoiceOption(rawValue: voiceRawValue) else { return }
        sessionCoordinator.selectVoice(voiceOption)
    }

    @objc private func toggleSoundEffects() {
        sessionCoordinator.setSoundEffectsEnabled(!sessionCoordinator.areSoundEffectsEnabled)
    }

    @objc private func replayIntro() {
        sessionCoordinator.replayIntro()
    }

    @objc private func startSage() {
        sessionCoordinator.startOnboarding()
    }

    @objc private func requestMicrophone() {
        permissions.requestMicrophonePermission()
    }

    @objc private func requestSpeechRecognition() {
        permissions.requestSpeechRecognitionPermission()
    }

    @objc private func requestAccessibility() {
        permissions.requestAccessibilityPermission()
    }

    @objc private func revealSageInFinder() {
        permissions.revealAppInFinderForAccessibility()
    }

    @objc private func requestScreenRecording() {
        permissions.requestScreenRecordingPermission()
    }

    @objc private func requestScreenContent() {
        permissions.requestScreenContentPermission()
    }

    @objc private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitSage() {
        NSApp.terminate(nil)
    }
}
