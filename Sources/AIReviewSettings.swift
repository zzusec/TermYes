import Combine
import Foundation

struct AIReviewModel: Identifiable, Equatable {
    let id: String
    var name: String
    var endpoint: String
    var model: String
    var apiKeyEnv: String
    var timeoutSeconds: Double
    var attempts: Int
    var maxResponseTokens: Int
    var wireAPI: String
}

@MainActor
final class AIReviewController: ObservableObject {
    static let shared = AIReviewController()

    @Published private(set) var isEnabled = false
    @Published private(set) var models: [AIReviewModel] = []
    @Published private(set) var selectedModelID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var learningEnabled = true
    @Published private(set) var learnedCommandCount = 0
    @Published private(set) var learnedPatternCount = 0
    @Published private(set) var syncEnabled = false
    @Published private(set) var syncPath = ""

    private var document: [String: Any] = [:]
    private var readFailed = false
    private let configURL: URL

    init(configURL: URL = AIReviewController.defaultConfigURL) {
        self.configURL = configURL
        reload()
    }

    nonisolated static var defaultConfigURL: URL {
        if let override = ProcessInfo.processInfo.environment["TERMOSAIC_AI_REVIEW_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Termosaic/AgentGuard", isDirectory: true)
            .appendingPathComponent("ai-review.json")
    }

    var selectedModel: AIReviewModel? {
        models.first(where: { $0.id == selectedModelID }) ?? models.first
    }

    func reload() {
        readFailed = false
        do {
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                document = [:]
                isEnabled = false
                models = []
                selectedModelID = nil
                learningEnabled = true
                learnedCommandCount = 0
                learnedPatternCount = 0
                syncEnabled = false
                syncPath = ""
                errorMessage = nil
                return
            }
            let data = try Data(contentsOf: configURL)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SettingsError.invalidDocument
            }
            document = value
            models = Self.models(from: value)
            selectedModelID = value["selected_model_id"] as? String
            if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = models.first?.id
            }
            isEnabled = value["enabled"] as? Bool ?? false
            learningEnabled = value["learning_enabled"] as? Bool ?? true
            learnedCommandCount = Self.learnedCommandCount(from: value, configURL: configURL)
            learnedPatternCount = Self.learnedPatternCount(from: value, configURL: configURL)
            syncEnabled = value["sync_enabled"] as? Bool ?? false
            syncPath = value["sync_path"] as? String ?? ""
            errorMessage = nil
        } catch {
            readFailed = true
            document = [:]
            models = []
            selectedModelID = nil
            isEnabled = false
            learningEnabled = true
            learnedCommandCount = 0
            learnedPatternCount = 0
            syncEnabled = false
            syncPath = ""
            errorMessage = "读取审批模型失败：\(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard canSave else { return }
        guard !enabled || selectedModel != nil else {
            errorMessage = "请先配置审核模型，再启用 AI reviewer"
            return
        }
        isEnabled = enabled
        persist()
    }

    func select(_ modelID: String) {
        guard canSave else { return }
        guard models.contains(where: { $0.id == modelID }) else { return }
        selectedModelID = modelID
        persist()
    }

    func setLearningEnabled(_ enabled: Bool) {
        guard canSave else { return }
        learningEnabled = enabled
        persist()
    }

    func setSyncEnabled(_ enabled: Bool) {
        guard canSave else { return }
        syncEnabled = enabled
        if enabled && syncPath.isEmpty {
            syncPath = Self.defaultSyncURL.path
        }
        persist()
    }

    @discardableResult
    func add(
        name: String,
        endpoint: String,
        model: String,
        apiKeyEnv: String
    ) -> Bool {
        guard canSave else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyEnv = apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !model.isEmpty,
              let url = URL(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            errorMessage = "请填写名称、模型 ID，以及有效的 HTTP(S) 地址"
            return false
        }
        if !apiKeyEnv.isEmpty,
           apiKeyEnv.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
            errorMessage = "密钥环境变量只能包含字母、数字和下划线"
            return false
        }

        let value = AIReviewModel(
            id: UUID().uuidString,
            name: name,
            endpoint: endpoint,
            model: model,
            apiKeyEnv: apiKeyEnv,
            timeoutSeconds: 10,
            attempts: 2,
            maxResponseTokens: 800,
            wireAPI: Self.wireAPI(for: endpoint)
        )
        models.append(value)
        selectedModelID = value.id
        errorMessage = nil
        return persist()
    }

    func remove(_ modelID: String) {
        guard canSave else { return }
        models.removeAll(where: { $0.id == modelID })
        if selectedModelID == modelID {
            selectedModelID = models.first?.id
        }
        if models.isEmpty {
            isEnabled = false
        }
        persist()
    }

    private var canSave: Bool {
        guard !readFailed else {
            errorMessage = "配置读取失败，请修复配置文件后重新打开模型设置；未覆盖原文件"
            return false
        }
        return true
    }

    @discardableResult
    private func persist() -> Bool {
        var value = document
        value["enabled"] = isEnabled
        value["learning_enabled"] = learningEnabled
        value["sync_enabled"] = syncEnabled
        if !syncPath.isEmpty {
            value["sync_path"] = syncPath
        }
        let originals = document["models"] as? [[String: Any]] ?? []
        value["models"] = models.map { model in
            var entry = originals.first { $0["id"] as? String == model.id } ?? [:]
            entry.merge(Self.dictionary(from: model)) { _, new in new }
            return entry
        }
        if let selectedModelID {
            value["selected_model_id"] = selectedModelID
        } else {
            value.removeValue(forKey: "selected_model_id")
        }

        if let selected = selectedModel {
            value["endpoint"] = selected.endpoint
            value["model"] = selected.model
            value["api_key_env"] = selected.apiKeyEnv
            value["timeout_seconds"] = selected.timeoutSeconds
            value["attempts"] = selected.attempts
            value["max_response_tokens"] = selected.maxResponseTokens
            value["wire_api"] = selected.wireAPI
        } else {
            for key in ["endpoint", "model", "api_key_env", "timeout_seconds", "attempts", "max_response_tokens", "wire_api"] {
                value.removeValue(forKey: key)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
            document = value
            errorMessage = nil
            return true
        } catch {
            let message = "保存审批模型失败：\(error.localizedDescription)"
            reload()
            errorMessage = message
            return false
        }
    }

    private static func models(from document: [String: Any]) -> [AIReviewModel] {
        if let values = document["models"] as? [[String: Any]], !values.isEmpty {
            let parsed: [AIReviewModel] = values.enumerated().compactMap { index, value in
                guard let endpoint = value["endpoint"] as? String,
                      let model = value["model"] as? String,
                      !endpoint.isEmpty, !model.isEmpty else { return nil }
                let id = value["id"] as? String ?? "model-\(index + 1)"
                return AIReviewModel(
                    id: id,
                    name: value["name"] as? String ?? model,
                    endpoint: endpoint,
                    model: model,
                    apiKeyEnv: value["api_key_env"] as? String ?? "",
                    timeoutSeconds: value["timeout_seconds"] as? Double ?? 10,
                    attempts: value["attempts"] as? Int ?? 2,
                    maxResponseTokens: value["max_response_tokens"] as? Int ?? 800,
                    wireAPI: value["wire_api"] as? String ?? wireAPI(for: endpoint)
                )
            }
            if !parsed.isEmpty { return parsed }
        }

        guard let endpoint = document["endpoint"] as? String,
              let model = document["model"] as? String,
              !endpoint.isEmpty, !model.isEmpty else { return [] }
        return [
            AIReviewModel(
                id: document["selected_model_id"] as? String ?? "default",
                name: model,
                endpoint: endpoint,
                model: model,
                apiKeyEnv: document["api_key_env"] as? String ?? "",
                timeoutSeconds: document["timeout_seconds"] as? Double ?? 10,
                attempts: document["attempts"] as? Int ?? 2,
                maxResponseTokens: document["max_response_tokens"] as? Int ?? 800,
                wireAPI: document["wire_api"] as? String ?? wireAPI(for: endpoint)
            )
        ]
    }

    private static func wireAPI(for endpoint: String) -> String {
        switch URL(string: endpoint)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last {
        case "messages": return "anthropic"
        case "responses": return "responses"
        default: return "chat"
        }
    }

    private static func dictionary(from model: AIReviewModel) -> [String: Any] {
        [
            "id": model.id,
            "name": model.name,
            "endpoint": model.endpoint,
            "model": model.model,
            "api_key_env": model.apiKeyEnv,
            "timeout_seconds": model.timeoutSeconds,
            "attempts": model.attempts,
            "max_response_tokens": model.maxResponseTokens,
            "wire_api": model.wireAPI,
        ]
    }

    private static func learnedCommandCount(from document: [String: Any], configURL: URL) -> Int {
        learnedMemoryCount(from: document, configURL: configURL, key: "commands")
    }

    private static func learnedPatternCount(from document: [String: Any], configURL: URL) -> Int {
        learnedMemoryCount(from: document, configURL: configURL, key: "patterns")
    }

    private static func learnedMemoryCount(
        from document: [String: Any],
        configURL: URL,
        key: String
    ) -> Int {
        var paths: [URL] = []
        if let override = document["memory_path"] as? String, !override.isEmpty {
            paths.append(URL(fileURLWithPath: override).standardizedFileURL)
        } else {
            paths.append(configURL.deletingLastPathComponent().appendingPathComponent("ai-review-memory.json"))
        }
        if document["sync_enabled"] as? Bool == true {
            let sync: URL
            if let override = document["sync_path"] as? String, !override.isEmpty {
                sync = URL(fileURLWithPath: override).standardizedFileURL
            } else {
                sync = defaultSyncURL
            }
            paths.append(sync)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: sync.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ) {
                paths.append(contentsOf: files.filter {
                    $0.lastPathComponent.hasPrefix(sync.deletingPathExtension().lastPathComponent)
                        && $0.pathExtension == "json"
                        && $0 != sync
                })
            }
        }

        var values = Set<String>()
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = value[key] as? [String: Any] else { continue }
            values.formUnion(entries.keys)
        }
        return values.count
    }

    private static var defaultSyncURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/TermYes", isDirectory: true)
            .appendingPathComponent("ai-review-memory.json")
    }

    private enum SettingsError: LocalizedError {
        case invalidDocument

        var errorDescription: String? {
            "配置根节点必须是 JSON 对象"
        }
    }
}
