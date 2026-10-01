import AppKit

/// Lets the user set the start time by scrolling: 5 minutes per notch, one hour with ⇧.
private final class ScrollDatePicker: NSDatePicker {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let step = event.modifierFlags.contains(.shift) ? 60 : 5
        let direction = event.scrollingDeltaY > 0 ? 1 : -1
        dateValue = Calendar.current.date(byAdding: .minute, value: direction * step, to: dateValue) ?? dateValue
    }
}

/// Lets the user pick any start time for the five-hour windows without a 24-row menu.
@MainActor
final class WindowSchedulePicker: NSObject {
    static let shared = WindowSchedulePicker()

    private var panel: NSPanel?
    private var picker: NSDatePicker?
    private var claudeCheckbox: NSButton?
    private var codexCheckbox: NSButton?
    private var confirmButton: NSButton?

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AutoContinueController.shared

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 155),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "定时激活5h窗口"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let label = NSTextField(labelWithString: "起始时间")
        let picker = ScrollDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = controller.windowStartDate ?? Date()

        let claudeCheckbox = NSButton(checkboxWithTitle: "Claude", target: self, action: #selector(updateConfirm))
        claudeCheckbox.state = controller.windowAgents.contains(.claude) ? .on : .off
        let codexCheckbox = NSButton(checkboxWithTitle: "Codex", target: self, action: #selector(updateConfirm))
        codexCheckbox.state = controller.windowAgents.contains(.codex) ? .on : .off

        let hint = NSTextField(labelWithString: "启动缺失窗口，并发送一句问候；每 5 小时一轮")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let disable = button(title: "停用", action: #selector(disableWindows))
        disable.isEnabled = controller.windowStartMinutes != nil
        let cancel = button(title: "取消", action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = button(title: "好", action: #selector(confirmSelection))
        confirm.keyEquivalent = "\r"
        confirm.isEnabled = !controller.windowAgents.isEmpty

        for view in [label, picker, claudeCheckbox, codexCheckbox, hint, disable, cancel, confirm] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(view)
        }

        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            picker.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            picker.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 120),

            claudeCheckbox.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            claudeCheckbox.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            codexCheckbox.leadingAnchor.constraint(equalTo: claudeCheckbox.trailingAnchor, constant: 18),
            codexCheckbox.centerYAnchor.constraint(equalTo: claudeCheckbox.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: claudeCheckbox.bottomAnchor, constant: 8),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            confirm.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            confirm.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            confirm.widthAnchor.constraint(equalToConstant: 74),

            cancel.trailingAnchor.constraint(equalTo: confirm.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 74),

            disable.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            disable.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            disable.widthAnchor.constraint(equalToConstant: 68)
        ])

        self.panel = panel
        self.picker = picker
        self.claudeCheckbox = claudeCheckbox
        self.codexCheckbox = codexCheckbox
        self.confirmButton = confirm
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(confirm)
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func close() {
        panel?.close()
        panel = nil
        picker = nil
        claudeCheckbox = nil
        codexCheckbox = nil
        confirmButton = nil
    }

    @objc private func updateConfirm() {
        confirmButton?.isEnabled = selectedAgents != []
    }

    private var selectedAgents: Set<ScheduledAgent> {
        var agents: Set<ScheduledAgent> = []
        if claudeCheckbox?.state == .on { agents.insert(.claude) }
        if codexCheckbox?.state == .on { agents.insert(.codex) }
        return agents
    }

    @objc private func disableWindows() {
        AutoContinueController.shared.setWindowSchedule(minutes: nil, agents: selectedAgents)
        close()
    }

    @objc private func confirmSelection() {
        guard let picker else { return close() }
        let components = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        guard let hour = components.hour, let minute = components.minute else { return close() }
        AutoContinueController.shared.setWindowSchedule(minutes: hour * 60 + minute, agents: selectedAgents)
        close()
    }
}
