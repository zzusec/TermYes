import Foundation

@main
struct AgentUpdateReportTests {
    static func main() throws {
        let json = """
        {"message":"test","items":[
          {"client":"codex","target":"CLI","command":"npm install", "ok":true,"changed":true,"detail":"done", "currentVersion":"1.0.0","latestVersion":"1.1.0","status":"updated","source":"https://registry.npmjs.org/@openai/codex"},
          {"client":"pi","target":"CLI","command":"", "ok":false,"changed":false,"detail":"offline", "status":"failed","currentVersion":"","latestVersion":""},
          {"client":"claude","target":"plugin","command":"plugin update", "ok":true,"changed":false,"detail":"done"}
        ]}
        """
        let report = try JSONDecoder().decode(AgentAutoUpdateReport.self, from: Data(json.utf8))
        precondition(report.items[0].stateDescription == "已自动升级")
        precondition(report.items[0].versionDescription.contains("1.0.0 / 官方 1.1.0"))
        precondition(report.items[0].diagnosticDetails.contains("https://registry.npmjs.org/"))
        precondition(report.items[1].stateDescription.contains("失败"))
        precondition(report.items[1].versionDescription == "本机 未知 / 官方 未知")
        precondition(report.items[2].stateDescription == "已完成", "Legacy plugin results remain readable")
        print("Agent update UI report tests passed: versions, failures, official sources, legacy plugin fields.")
    }
}
