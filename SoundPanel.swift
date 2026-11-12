import Cocoa
import CoreAudio

// MARK: - Slider

/// Thin tinted track with a small light pill-shaped knob, like the slider in Control Center's Sound panel.
final class VolumeSlider: NSView {
    var value: Float = 0.5 { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    var onChange: ((Float) -> Void)?

    private let knobWidth: CGFloat = 18
    private let knobHeight: CGFloat = 14
    private let trackHeight: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let travel = bounds.width - knobWidth
        let knobX = knobWidth / 2 + travel * CGFloat(min(1, max(0, value)))
        let track = NSRect(x: 0, y: (bounds.height - trackHeight) / 2, width: bounds.width, height: trackHeight)

        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        var filled = track
        filled.size.width = knobX
        (NSColor.controlAccentColor.blended(withFraction: 0.4, of: .white) ?? .white).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let knob = NSRect(x: knobX - knobWidth / 2, y: (bounds.height - knobHeight) / 2, width: knobWidth, height: knobHeight)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knobHeight / 2, yRadius: knobHeight / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Follows the mouse until the button is released, wherever it goes. Inside a menu the view only receives drag
    /// events while the cursor stays within it, so a fast drag that strays above, below or outside the menu would
    /// freeze the slider. Like a real slider, this runs its own tracking loop from mouseDown.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        update(from: event)
        guard let window else { return }

        // Waiting at most 100 ms per event and checking the button state means this can never hang.
        while NSEvent.pressedMouseButtons & 1 != 0 {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            if next.type == .leftMouseUp { break }
            update(from: next)
            displayIfNeeded()
        }
    }

    override func mouseDragged(with event: NSEvent) { update(from: event) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Volume" }
    override func accessibilityValue() -> Any? { Int((value * 100).rounded()) }
    override func accessibilityPerformIncrement() -> Bool { nudge(by: 1.0 / 16.0) }
    override func accessibilityPerformDecrement() -> Bool { nudge(by: -1.0 / 16.0) }

    private func nudge(by amount: Float) -> Bool {
        guard isEnabled else { return false }
        value = min(1, max(0, value + amount))
        onChange?(value)
        return true
    }

    private func update(from event: NSEvent) {
        guard isEnabled else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let v = Float(min(1, max(0, (x - knobWidth / 2) / (bounds.width - knobWidth))))
        value = v
        onChange?(v)
    }
}

// MARK: - Rows

/// A clickable row with a subtle hover highlight.
class HoverRow: NSView {
    var onClick: (() -> Void)?
    var accessibilityText: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        // Resolve the dynamic colour in this view's own (menu) appearance, not the app's.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

private func label(
    _ text: String,
    size: CGFloat = 13,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

private final class DeviceRow: HoverRow {
    static let height: CGFloat = 32

    private let circle = NSView()
    private let isSelected: Bool
    private let deviceName: String
    private let batteryText = label("", size: 12, color: .secondaryLabelColor)
    private let batteryIcon = NSImageView()

    init(device: OutputDevice, selected: Bool, frame: NSRect) {
        isSelected = selected
        deviceName = device.name
        super.init(frame: frame)
        accessibilityText = device.name

        let circleSize: CGFloat = 26
        circle.frame = NSRect(x: 8, y: (frame.height - circleSize) / 2, width: circleSize, height: circleSize)
        circle.wantsLayer = true
        circle.layer?.cornerRadius = circleSize / 2
        addSubview(circle)

        let icon = NSImageView(frame: circle.bounds)
        icon.image = symbol(device.symbolName, size: 12)
        icon.contentTintColor = selected ? .white : .labelColor
        circle.addSubview(icon)

        // Bluetooth devices get room on the right for the battery level.
        let textX = 8 + circleSize + 7
        let reserved: CGFloat = device.bluetoothAddress != nil ? 78 : 8
        let name = label(device.name)
        name.frame = NSRect(x: textX, y: (frame.height - 18) / 2, width: frame.width - textX - reserved, height: 18)
        addSubview(name)

        batteryIcon.frame = NSRect(x: frame.width - 8 - 24, y: (frame.height - 18) / 2, width: 24, height: 18)
        batteryText.alignment = .right
        batteryText.frame = NSRect(x: batteryIcon.frame.minX - 4 - 40, y: (frame.height - 16) / 2, width: 40, height: 16)
        batteryIcon.isHidden = true
        batteryText.isHidden = true
        addSubview(batteryIcon)
        addSubview(batteryText)

        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the battery level, or hides it when unknown.
    func setBattery(_ percent: Int?) {
        guard let percent else {
            batteryIcon.isHidden = true
            batteryText.isHidden = true
            accessibilityText = deviceName
            return
        }
        let symbolName: String
        switch percent {
        case 88...: symbolName = "battery.100percent"
        case 63...: symbolName = "battery.75percent"
        case 38...: symbolName = "battery.50percent"
        case 13...: symbolName = "battery.25percent"
        default: symbolName = "battery.0percent"
        }
        batteryText.stringValue = "\(percent)%"
        batteryIcon.image = symbol(symbolName, size: 15, weight: .regular)
        batteryIcon.contentTintColor = percent <= 20 ? .systemRed : .secondaryLabelColor
        batteryIcon.isHidden = false
        batteryText.isHidden = false
        accessibilityText = "\(deviceName), battery \(percent) percent"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            circle.layer?.backgroundColor = (isSelected
                ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.15)).cgColor
        }
    }
}

// MARK: - Icon buttons

/// A speaker icon that works as a button, with a larger click area than the glyph itself.
private final class IconButton: NSImageView {
    var onClick: (() -> Void)?
    var accessibilityText: String?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.55 }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - Panel content

/// The contents of the Sound menu. Laid out by hand (fixed row heights), so it sizes itself without Auto Layout.
final class SoundPanelContent: NSView {
    static let width: CGFloat = 306

    let slider = VolumeSlider()
    let selectedDevice: AudioDeviceID
    /// Scroll events over the menu contents (the slider has no scrolling of its own).
    var onScroll: ((NSEvent) -> Void)?
    /// The speaker icons at either end of the slider: all the way down, and all the way up.
    var onMute: (() -> Void)?
    var onMax: (() -> Void)?
    private var rows: [AudioDeviceID: DeviceRow] = [:]

    override var isFlipped: Bool { true }

    init(
        devices: [OutputDevice],
        selected: AudioDeviceID,
        onSelect: @escaping (OutputDevice) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        selectedDevice = selected
        super.init(frame: .zero)

        let w = Self.width
        let inset: CGFloat = 13
        var y: CGFloat = 8

        let title = label("Sound", weight: .semibold)
        title.frame = NSRect(x: inset, y: y, width: w - inset * 2, height: 16)
        addSubview(title)
        y = 29

        // Click areas are wider than the glyphs but stop where the slider starts and ends.
        let low = IconButton(image: symbol("speaker.fill", size: 15) ?? NSImage())
        low.contentTintColor = .secondaryLabelColor
        low.frame = NSRect(x: 10, y: y, width: 24, height: 24)
        low.accessibilityText = "Mute"
        low.onClick = { [weak self] in self?.onMute?() }
        addSubview(low)

        let high = IconButton(image: symbol("speaker.wave.3.fill", size: 15) ?? NSImage())
        high.contentTintColor = .secondaryLabelColor
        high.frame = NSRect(x: w - 38, y: y, width: 28, height: 24)
        high.accessibilityText = "Maximum volume"
        high.onClick = { [weak self] in self?.onMax?() }
        addSubview(high)

        slider.frame = NSRect(x: 34, y: y, width: w - 34 - 40, height: 24)
        addSubview(slider)
        y += 24 + 8

        addSeparator(at: y)
        y += 1 + 8

        let output = label("Output", size: 12, weight: .semibold, color: .secondaryLabelColor)
        output.frame = NSRect(x: inset, y: y, width: w - inset * 2, height: 16)
        addSubview(output)
        y += 16 + 3

        for device in devices {
            let row = DeviceRow(
                device: device,
                selected: device.id == selected,
                frame: NSRect(x: 5, y: y, width: w - 10, height: DeviceRow.height)
            )
            row.onClick = { onSelect(device) }
            rows[device.id] = row
            addSubview(row)
            y += DeviceRow.height
        }
        y += 2

        addSeparator(at: y)
        y += 1 + 4

        let settings = HoverRow(frame: NSRect(x: 5, y: y, width: w - 10, height: 24))
        let settingsLabel = label("Sound Settings…")
        settingsLabel.frame = NSRect(x: 8, y: 3, width: settings.frame.width - 16, height: 18)
        settings.addSubview(settingsLabel)
        settings.accessibilityText = "Sound Settings"
        settings.onClick = onOpenSettings
        addSubview(settings)
        y += 24

        frame = NSRect(x: 0, y: 0, width: w, height: y)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    /// Shows a device's battery level; nil hides it.
    func setBattery(_ percent: Int?, for id: AudioDeviceID) { rows[id]?.setBattery(percent) }

    private func addSeparator(at y: CGFloat) {
        let line = NSBox(frame: NSRect(x: 6, y: y, width: Self.width - 12, height: 1))
        line.boxType = .separator
        addSubview(line)
    }
}
