import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let audio = AudioController()
    var monitors: [Any] = []

    /// The Sound menu while it is open. It is a real NSMenu, so the system draws the glass, corners,
    /// shadow, position and the status item's active highlight.
    var soundMenu: NSMenu?
    var content: SoundPanelContent?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Launch at login error: \(error)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        audio.onChange = { [weak self] in self?.audioChanged() }
        audio.start()
        refreshStatusIcon()

        // Local monitors see events aimed at our own windows (status item, open menu);
        // global monitors see events aimed at every other app.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            (self?.handleScroll(event) ?? false) ? nil : event
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            _ = self?.handleScroll(event)
        }) { monitors.append(m) }
    }

    // MARK: - Status item

    @objc func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            showSoundMenu()
        }
    }

    func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let pct = Int((audio.volume * 100).rounded())
        let name: String
        switch (audio.isMuted, pct) {
        case (true, _), (_, 0): name = "speaker.slash.fill"
        case (_, 1...33): name = "speaker.wave.1.fill"
        case (_, 34...66): name = "speaker.wave.2.fill"
        default: name = "speaker.wave.3.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        button.title = (audio.isMuted || pct == 0) ? " Muted" : " \(pct)%"
    }

    // MARK: - Sound menu

    func showSoundMenu() {
        let view = SoundPanelContent(
            devices: audio.outputDevices(),
            selected: audio.defaultOutputDevice,
            onSelect: { [weak self] device in
                self?.audio.setDefaultOutput(device.id)
                self?.soundMenu?.cancelTracking()
            },
            onOpenSettings: { [weak self] in
                self?.soundMenu?.cancelTracking()
                self?.openSoundSettings()
            }
        )
        view.slider.value = audio.volume
        view.slider.isEnabled = audio.canSetVolume
        view.slider.onChange = { [weak self] value in
            self?.audio.setVolume(value)
            self?.refreshStatusIcon()
        }
        view.onScroll = { [weak self] event in self?.handleScroll(event) }
        content = view

        let item = NSMenuItem()
        item.view = view
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(item)
        soundMenu = menu

        // Showing it through the status item gives the native anchoring and active highlight.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === soundMenu {
            soundMenu = nil
            content = nil
        }
    }

    func audioChanged() {
        refreshStatusIcon()
        content?.slider.value = audio.volume
        content?.slider.isEnabled = audio.canSetVolume
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scroll

    /// Changes the volume if the cursor is over the menu bar icon or the open Sound menu.
    /// Returns true when the event was ours (so a local monitor can swallow it).
    @discardableResult
    func handleScroll(_ event: NSEvent) -> Bool {
        let mouse = NSEvent.mouseLocation

        var overIcon = false
        if let button = statusItem.button, let window = button.window {
            overIcon = window.convertToScreen(button.convert(button.bounds, to: nil)).contains(mouse)
        }
        let overMenu = content?.window?.frame.contains(mouse) ?? false
        guard overIcon || overMenu else { return false }

        // Trackpad momentum would keep nudging the volume after the fingers lift.
        guard event.momentumPhase.isEmpty else { return true }

        // Make physical "up" (wheel away, or fingers up) mean louder regardless of
        // the natural-scrolling setting.
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return true }

        let change: Float = event.hasPreciseScrollingDeltas
            ? Float(delta) * 0.004
            : (delta > 0 ? 1 : -1) * (1.0 / 16.0)

        let newVolume = min(1, max(0, audio.volume + change))
        audio.setVolume(newVolume)
        content?.slider.value = newVolume
        refreshStatusIcon()
        return true
    }

    // MARK: - Right-click menu

    func showMenu() {
        let menu = NSMenu()

        let pct = Int((audio.volume * 100).rounded())
        let header = NSMenuItem(title: "Volume: \(pct)%", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let mute = NSMenuItem(
            title: audio.isMuted ? "Unmute" : "Mute",
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        mute.target = self
        menu.addItem(mute)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit VolumeScroll",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func toggleMute() {
        audio.setMuted(!audio.isMuted)
        refreshStatusIcon()
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLogin = !launchAtLogin
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
    }
}
