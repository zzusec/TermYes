import Foundation

struct GitHubReleaseLocation: Sendable {
    let tagName: String
    let dmgURL: URL
    let checksumURL: URL

    init?(redirectedURL: URL) {
        guard let components = URLComponents(url: redirectedURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }

        let prefix = "/zzusec/TermYes/releases/tag/"
        guard components.percentEncodedPath.hasPrefix(prefix) else { return nil }
        let tag = String(components.percentEncodedPath.dropFirst(prefix.count))
        guard tag.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              let version = SemanticVersion(tag) else { return nil }

        let filename = "TermYes-v\(version)-macOS.dmg"
        let downloadBase = URL(string: "https://github.com/zzusec/TermYes/releases/download/\(tag)/")!
        tagName = tag
        dmgURL = downloadBase.appendingPathComponent(filename)
        checksumURL = downloadBase.appendingPathComponent("\(filename).sha256")
    }
}
