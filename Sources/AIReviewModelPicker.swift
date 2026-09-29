import AppKit

@MainActor
final class AIReviewModelPicker: NSObject {
    static let shared = AIReviewModelPicker()

    private var panel: NSPanel?
    private var modelStack: NSStackView?
    private var nameField: NSTextField?
    private var modelField: NSTextField?
    private var endpointField: NSTextField?
    private var apiKeyField: NSTextField?
    private var errorLabel: NSTextField?

    func show() {
        AIReviewController.shared.reload()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI 审批模型"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let title = NSTextField(labelWithString: "已配置模型")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let modelStack = NSStackView()
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 6

        let divider = NSBox()
        divider.boxType = .separator
        let addTitle = NSTextField(labelWithString: "添加模型")
        addTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let nameField = textField(placeholder: "显示名称")
        let modelField = textField(placeholder: "模型 ID，例如 cline-pass/qwen3.8-max")
        let endpointField = textField(placeholder: "API 地址")
        let apiKeyField = textField(placeholder: "密钥环境变量（可选）")

        let controller = AIReviewController.shared
        if let selected = controller.selectedModel {
            endpointField.stringValue = selected.endpoint
            apiKeyField.stringValue = selected.apiKeyEnv
        } else {
            endpointField.stringValue = "http://127.0.0.1:15722/v1/chat/completions"
        }

        let errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail

        let cancel = button(title: "关闭", action: #selector(close))
        let add = button(title: "添加并选择", action: #selector(addModel))
        add.keyEquivalent = "\r"

        let content = panel.contentView!
        let views: [NSView] = [
            title, modelStack, divider, addTitle,
            nameField, modelField, endpointField, apiKeyField,
            errorLabel, cancel, add,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            modelStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            modelStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            modelStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            modelStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
            modelStack.heightAnchor.constraint(lessThanOrEqualToConstant: 118),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            divider.topAnchor.constraint(equalTo: modelStack.bottomAnchor, constant: 12),

            addTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            addTitle.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nameField.topAnchor.constraint(equalTo: addTitle.bottomAnchor, constant: 10),

            modelField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            modelField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            modelField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),

            endpointField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            endpointField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            endpointField.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 8),

            apiKeyField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            apiKeyField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            apiKeyField.topAnchor.constraint(equalTo: endpointField.bottomAnchor, constant: 8),

            errorLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 8),

            add.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            add.widthAnchor.constraint(equalToConstant: 112),

            cancel.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 74),
        ])

        self.panel = panel
        self.modelStack = modelStack
        self.nameField = nameField
        self.modelField = modelField
        self.endpointField = endpointField
        self.apiKeyField = apiKeyField
        self.errorLabel = errorLabel
        rebuildModels()

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nameField)
    }

    private func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func rebuildModels() {
        guard let stack = modelStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let controller = AIReviewController.shared
        if controller.models.isEmpty {
            let empty = NSTextField(labelWithString: "尚未添加审批模型")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }

        for model in controller.models {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8

            let radio = NSButton(
                radioButtonWithTitle: model.name,
                target: self,
                action: #selector(selectModel(_:))
            )
            radio.state = model.id == controller.selectedModelID ? .on : .off
            radio.identifier = NSUserInterfaceItemIdentifier(model.id)
            radio.lineBreakMode = .byTruncatingTail

            let detail = NSTextField(labelWithString: model.model)
            detail.textColor = .secondaryLabelColor
            detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            detail.lineBreakMode = .byTruncatingMiddle

            let delete = NSButton(
                image: NSImage(systemSymbolName: "trash", accessibilityDescription: "删除模型")!,
                target: self,
                action: #selector(deleteModel(_:))
            )
            delete.bezelStyle = .texturedRounded
            delete.identifier = NSUserInterfaceItemIdentifier(model.id)
            delete.toolTip = "删除此模型"

            row.addArrangedSubview(radio)
            row.addArrangedSubview(detail)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(delete)
            radio.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func close() {
        panel?.close()
        panel = nil
        modelStack = nil
        nameField = nil
        modelField = nil
        endpointField = nil
        apiKeyField = nil
        errorLabel = nil
    }

    @objc private func selectModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        AIReviewController.shared.select(id)
        rebuildModels()
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        AIReviewController.shared.remove(id)
        rebuildModels()
    }

    @objc private func addModel() {
        let controller = AIReviewController.shared
        let added = controller.add(
            name: nameField?.stringValue ?? "",
            endpoint: endpointField?.stringValue ?? "",
            model: modelField?.stringValue ?? "",
            apiKeyEnv: apiKeyField?.stringValue ?? ""
        )
        errorLabel?.stringValue = controller.errorMessage ?? ""
        guard added else { return }
        nameField?.stringValue = ""
        modelField?.stringValue = ""
        apiKeyField?.stringValue = ""
        rebuildModels()
    }
}
