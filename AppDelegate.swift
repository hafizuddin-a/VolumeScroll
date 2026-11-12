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
    var shownDevices: [OutputDevice] = []
    /// Last known battery levels by Bluetooth address, shown instantly while a fresh reading loads.
    var batteryCache: [String: Int] = [:]

    /// What the UI shows. Updated instantly on every scroll event; CoreAudio calls take several milliseconds each,
    /// so reading the system volume back on every event made the number lag and then jump.
    var currentVolume: Float = 0.5
    var currentMuted = false
    var lastUserChange: TimeInterval = 0
    var resyncWork: DispatchWorkItem?

    /// Where the user's scrolling is heading. `currentVolume` eases toward it, so the number counts through
    /// every value instead of jumping when the wheel accelerates.
    var targetVolume: Float = 0.5
    private var easeTimer: Timer?

    /// Bumped on every user change. A background read of the system volume is only applied if the token is still
    /// the same when it finishes, so a slow (e.g. Bluetooth) device's stale values can never overwrite the user's.
    private var interactionToken = 0
    private var syncPending = false
    private var renderScheduled = false

    /// What the menu bar item currently shows, so it is only touched when something actually changes.
    private var shownSymbol = ""
    private var shownTitle = ""

    /// CoreAudio writes happen here, off the main thread, and are coalesced: only the newest value is sent.
    private let audioQueue = DispatchQueue(label: "volumescroll.audio", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingVolume: Float?

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
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        audio.onChange = { [weak self] in self?.audioChanged() }
        audio.start()
        syncFromSystem()
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

    /// Updates the menu bar item. Every property change is a message to the system's menu bar, and sending
    /// them on every scroll event made it fall behind and then jump, so only real changes are sent.
    func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let pct = Int((currentVolume * 100).rounded())
        let name: String
        switch (currentMuted, pct) {
        case (true, _), (_, 0): name = "speaker.slash.fill"
        case (_, 1...33): name = "speaker.wave.1.fill"
        case (_, 34...66): name = "speaker.wave.2.fill"
        default: name = "speaker.wave.3.fill"
        }
        if name != shownSymbol {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            image?.isTemplate = true
            button.image = image
            shownSymbol = name
        }
        let title = (currentMuted || pct == 0) ? " Muted" : " \(pct)%"
        if title != shownTitle {
            button.title = title
            shownTitle = title
        }
    }

    // MARK: - Sound menu

    func showSoundMenu() {
        scheduleSystemSync()
        shownDevices = audio.outputDevices()
        let view = SoundPanelContent(
            devices: shownDevices,
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
        view.slider.value = currentVolume
        view.slider.onChange = { [weak self] value in self?.setUserVolume(value) }
        view.onScroll = { [weak self] event in self?.handleScroll(event) }
        // The icons jump straight to the ends (no easing, unlike scrolling).
        view.onMute = { [weak self] in self?.setUserVolume(0) }
        view.onMax = { [weak self] in self?.setUserVolume(1) }
        content = view
        applyBatteries(to: view)
        refreshBatteries()

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

    /// Reads battery levels in the background. A device that has just connected may not have reported its level
    /// yet, so a missing one is retried a couple of times while the menu stays open.
    func refreshBatteries(retriesLeft: Int = 2) {
        guard shownDevices.contains(where: { $0.bluetoothAddress != nil }) else { return }
        BluetoothBattery.fetch { [weak self] levels in
            guard let self, let open = self.content else { return }
            if !levels.isEmpty {
                self.batteryCache = levels
                self.applyBatteries(to: open)
            }
            let missing = self.shownDevices.contains { device in
                device.bluetoothAddress.map { levels[$0] == nil } ?? false
            }
            if missing, retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.content != nil else { return }
                    // Not while the user is scrolling: keep the main run loop and the CPU free for that.
                    guard self.easeTimer == nil, ProcessInfo.processInfo.systemUptime - self.lastUserChange > 1 else { return }
                    self.refreshBatteries(retriesLeft: retriesLeft - 1)
                }
            }
        }
    }

    func applyBatteries(to view: SoundPanelContent) {
        for device in shownDevices {
            guard let address = device.bluetoothAddress else { continue }
            view.setBattery(batteryCache[address], for: device.id)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === soundMenu {
            soundMenu = nil
            content = nil
        }
    }

    /// CoreAudio reports changes, including the echo of our own writes. While the user is scrolling or dragging our
    /// value is ahead of those echoes, so they are ignored until things settle.
    func audioChanged() {
        guard easeTimer == nil, ProcessInfo.processInfo.systemUptime - lastUserChange > 0.5 else { return }
        scheduleSystemSync()
    }

    /// Reads the real volume on the audio queue, so a slow device can never stall the main thread. The queue is
    /// serial, so the read runs after any pending writes.
    func scheduleSystemSync() {
        guard !syncPending else { return }
        syncPending = true
        let token = interactionToken
        audioQueue.async { [weak self] in
            guard let self else { return }
            let volume = self.audio.volume
            let muted = self.audio.isMuted
            let settable = self.audio.canSetVolume
            DispatchQueue.main.async {
                self.syncPending = false
                // The user acted while we were reading: their value is newer than ours.
                guard token == self.interactionToken, self.easeTimer == nil else { return }
                self.currentVolume = volume
                self.targetVolume = volume
                self.currentMuted = muted
                self.refreshStatusIcon()
                self.content?.slider.value = volume
                self.content?.slider.isEnabled = settable
            }
        }
    }

    func syncFromSystem() {
        currentVolume = audio.volume
        targetVolume = currentVolume
        currentMuted = audio.isMuted
    }

    /// The one path for user-driven changes. Scrolling sets a target the volume eases toward; dragging the slider
    /// applies directly, because the slider already follows the pointer.
    func setUserVolume(_ newValue: Float, animated: Bool = false) {
        interactionToken += 1
        targetVolume = min(1, max(0, newValue))
        if targetVolume > 0 { currentMuted = false }
        lastUserChange = ProcessInfo.processInfo.systemUptime
        if animated {
            startEasing()
        } else {
            stopEasing()
            currentVolume = targetVolume
            content?.slider.value = currentVolume   // the knob follows the pointer immediately
            scheduleRender()
        }
        scheduleResync()
    }

    private func startEasing() {
        guard easeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.easeStep() }
        RunLoop.main.add(timer, forMode: .common)   // .common so it keeps firing while the menu is open
        easeTimer = timer
    }

    private func stopEasing() {
        easeTimer?.invalidate()
        easeTimer = nil
    }

    private func easeStep() {
        let diff = targetVolume - currentVolume
        if abs(diff) <= 0.002 {
            currentVolume = targetVolume
            stopEasing()
        } else {
            let step = min(max(abs(diff) * 0.22, 0.003), 0.03)   // never more than 3% in one frame
            currentVolume += diff > 0 ? min(step, diff) : -min(step, -diff)
        }
        render()
    }

    /// Dragging produces mouse events far faster than the menu bar can take updates (the same flood that made the
    /// number freeze and then leap while scrolling), so push to the menu bar and CoreAudio at most once per frame.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    /// Pushes `currentVolume` to the slider, the menu bar and (in the background) to CoreAudio.
    private func render() {
        content?.slider.value = currentVolume
        refreshStatusIcon()

        pendingLock.lock()
        let idle = pendingVolume == nil
        pendingVolume = currentVolume
        pendingLock.unlock()
        if idle { audioQueue.async { [weak self] in self?.flushPendingVolume() } }
    }

    /// Once the gesture ends, re-read the real value in case something else changed it meanwhile.
    private func scheduleResync() {
        resyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.easeTimer == nil else { self.scheduleResync(); return }
            self.scheduleSystemSync()
        }
        resyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func flushPendingVolume() {
        while true {
            pendingLock.lock()
            let value = pendingVolume
            pendingVolume = nil
            pendingLock.unlock()
            guard let value else { return }
            audio.setVolume(value)
        }
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

        // Trackpad: proportional to the finger movement. Wheel: 2% per notch, growing when you spin it fast.
        let change: Float = event.hasPreciseScrollingDeltas
            ? Float(delta) * 0.004
            : (delta > 0 ? 1 : -1) * 0.02 * Float(min(max(abs(delta), 1), 5))

        setUserVolume(targetVolume + change, animated: true)
        return true
    }

    // MARK: - Right-click menu

    func showMenu() {
        let menu = NSMenu()

        let pct = Int((currentVolume * 100).rounded())
        let header = NSMenuItem(title: "Volume: \(pct)%", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let mute = NSMenuItem(
            title: currentMuted ? "Unmute" : "Mute",
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
        currentMuted.toggle()
        audio.setMuted(currentMuted)
        refreshStatusIcon()
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLogin = !launchAtLogin
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
    }
}
