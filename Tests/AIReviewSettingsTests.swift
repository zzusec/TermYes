import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
@MainActor
struct AIReviewSettingsTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("termosaic-ai-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("ai-review.json")
        let memoryURL = root.appendingPathComponent("ai-review-memory.json")
        let syncURL = root.appendingPathComponent("icloud-memory.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "commands": ["abc": ["count": 1, "last_seen": "2026-09-29T00:00:00Z"]],
            "patterns": ["git status": ["count": 3, "last_seen": "2026-09-29T00:00:00Z"]],
        ]).write(to: memoryURL)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "commands": ["cloud": ["count": 1, "last_seen": "2026-09-29T01:00:00Z"]],
            "patterns": [:],
        ]).write(to: syncURL)
        let legacy: [String: Any] = [
            "enabled": true,
            "endpoint": "http://127.0.0.1:15722/v1/chat/completions",
            "model": "cline-pass/qwen3.8-max",
            "allowed_workspace_roots": ["/Users/hx10/Termosaic"],
            "allowed_temp_roots": ["/tmp", "/private/tmp"],
            "learning_enabled": true,
            "memory_path": memoryURL.path,
            "sync_enabled": true,
            "sync_path": syncURL.path,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: configURL)

        let controller = AIReviewController(configURL: configURL)
        expect(controller.models.count == 1, "legacy flat config should migrate to one model")
        expect(controller.selectedModel?.model == "cline-pass/qwen3.8-max", "legacy model should be selected")
        expect(controller.isEnabled, "legacy enabled state should be preserved")
        expect(controller.learningEnabled, "learning state should be loaded")
        expect(controller.learnedCommandCount == 2, "learned command count should merge local and cloud")
        expect(controller.learnedPatternCount == 1, "learned pattern count should be loaded")
        expect(controller.syncEnabled, "cloud sync should be loaded")

        var emptyModels = legacy
        emptyModels["models"] = []
        try JSONSerialization.data(withJSONObject: emptyModels).write(to: configURL)
        controller.reload()
        expect(controller.models.count == 1, "empty models should fall back to flat config")
        expect(controller.selectedModel?.model == "cline-pass/qwen3.8-max", "flat fallback model should remain selected")

        expect(
            controller.add(
                name: "Second",
                endpoint: "http://127.0.0.1:2222/v1/chat/completions",
                model: "model-second",
                apiKeyEnv: ""
            ),
            "valid model should be added"
        )
        expect(controller.models.count == 2, "model should be appended")
        guard let second = controller.selectedModel else {
            fatalError("new model should be selected")
        }
        expect(second.model == "model-second", "newly added model should become active")

        controller.select(controller.models[0].id)
        expect(controller.selectedModel?.model == "cline-pass/qwen3.8-max", "selection should persist")

        controller.remove(controller.models[0].id)
        expect(controller.models.count == 1, "removed model should disappear")
        expect(controller.selectedModel?.model == "model-second", "remaining model should become active")
        controller.setLearningEnabled(false)
        expect(!controller.learningEnabled, "learning should be disabled")
        controller.setSyncEnabled(false)
        expect(!controller.syncEnabled, "cloud sync should be disabled")

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        expect((saved?["models"] as? [[String: Any]])?.count == 1, "models array should be persisted")
        expect(saved?["model"] as? String == "model-second", "active flat model should be persisted")
        expect(saved?["enabled"] as? Bool == true, "enabled state should be persisted")
        expect(saved?["learning_enabled"] as? Bool == false, "learning setting should be persisted")
        expect(saved?["sync_enabled"] as? Bool == false, "sync setting should be persisted")
        expect(
            (saved?["allowed_temp_roots"] as? [String])?.contains("/private/tmp") == true,
            "temporary roots should be preserved"
        )

        let permissions = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600, "saved configuration should be private")

        controller.remove(second.id)
        controller.reload()
        expect(controller.models.isEmpty, "deleting the last model must not resurrect the flat fallback")
        expect(!controller.isEnabled, "removing all models should disable the reviewer")
        controller.setEnabled(true)
        expect(!controller.isEnabled, "reviewer cannot be enabled without a configured model")
        expect(controller.errorMessage != nil, "missing model prerequisite should be visible")

        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let blocked = AIReviewController(configURL: blockedParent.appendingPathComponent("ai-review.json"))
        expect(!blocked.add(name: "Unsaved", endpoint: "https://example.invalid/v1/messages", model: "test", apiKeyEnv: ""), "save failure must not report a successful add")
        expect(blocked.models.isEmpty, "failed save must restore persisted state")
        expect(blocked.errorMessage != nil, "save failure should remain visible")

        let invalid = AIReviewController(configURL: root.appendingPathComponent("invalid.json"))
        for endpoint in ["http:///path", "https://", "https://user:password@example.invalid/v1/chat/completions"] {
            expect(!invalid.add(name: "Invalid", endpoint: endpoint, model: "test", apiKeyEnv: ""), "malformed or credential-bearing endpoint must be rejected")
        }
        expect(invalid.add(name: "Messages", endpoint: "https://example.invalid/v1/messages", model: "test-messages", apiKeyEnv: ""), "messages model should save")
        let messageID = invalid.selectedModelID!
        expect(invalid.add(name: "Chat", endpoint: "https://example.invalid/v1/chat/completions", model: "test-chat", apiKeyEnv: ""), "chat model should save")
        invalid.select(messageID)
        let protocols = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("invalid.json"))) as! [String: Any]
        expect(protocols["wire_api"] as? String == "anthropic", "selected model protocol should persist")
        expect((protocols["models"] as? [[String: Any]])?.last?["wire_api"] as? String == "chat", "protocol must belong to each model")

        let corruptURL = root.appendingPathComponent("corrupt.json")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = AIReviewController(configURL: corruptURL)
        expect(!corrupt.add(name: "Overwrite", endpoint: "https://example.invalid/v1/chat/completions", model: "test", apiKeyEnv: ""), "unreadable config must not be overwritten")
        let preservedCorruptData = try Data(contentsOf: corruptURL)
        expect(preservedCorruptData == corruptData, "corrupt config should remain available for recovery")

        print("AI review settings tests passed.")
    }
}
