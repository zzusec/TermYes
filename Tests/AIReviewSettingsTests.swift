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
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "commands": ["abc": ["count": 1, "last_seen": "2026-09-29T00:00:00Z"]],
            "patterns": ["git status": ["count": 3, "last_seen": "2026-09-29T00:00:00Z"]],
        ]).write(to: memoryURL)
        let legacy: [String: Any] = [
            "enabled": true,
            "endpoint": "http://127.0.0.1:15722/v1/chat/completions",
            "model": "cline-pass/qwen3.8-max",
            "allowed_workspace_roots": ["/Users/hx10/Termosaic"],
            "allowed_temp_roots": ["/tmp", "/private/tmp"],
            "learning_enabled": true,
            "memory_path": memoryURL.path,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: configURL)

        let controller = AIReviewController(configURL: configURL)
        expect(controller.models.count == 1, "legacy flat config should migrate to one model")
        expect(controller.selectedModel?.model == "cline-pass/qwen3.8-max", "legacy model should be selected")
        expect(controller.isEnabled, "legacy enabled state should be preserved")
        expect(controller.learningEnabled, "learning state should be loaded")
        expect(controller.learnedCommandCount == 1, "learned command count should be loaded")
        expect(controller.learnedPatternCount == 1, "learned pattern count should be loaded")

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

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        expect((saved?["models"] as? [[String: Any]])?.count == 1, "models array should be persisted")
        expect(saved?["model"] as? String == "model-second", "active flat model should be persisted")
        expect(saved?["enabled"] as? Bool == true, "enabled state should be persisted")
        expect(saved?["learning_enabled"] as? Bool == false, "learning setting should be persisted")
        expect(
            (saved?["allowed_temp_roots"] as? [String])?.contains("/private/tmp") == true,
            "temporary roots should be preserved"
        )

        print("AI review settings tests passed.")
    }
}
