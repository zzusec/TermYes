import Foundation

@main
struct ReleaseLocationTests {
    static func main() {
        let release = GitHubReleaseLocation(redirectedURL: URL(string: "https://github.com/zzusec/TermYes/releases/tag/v1.6.18")!)
        expect(release?.tagName == "v1.6.18", "release tag should be extracted")
        expect(release?.dmgURL.absoluteString == "https://github.com/zzusec/TermYes/releases/download/v1.6.18/TermYes-v1.6.18-macOS.dmg", "DMG URL should match the verified tag")
        expect(release?.checksumURL.absoluteString == "https://github.com/zzusec/TermYes/releases/download/v1.6.18/TermYes-v1.6.18-macOS.dmg.sha256", "checksum URL should match the verified tag")

        for invalidURL in [
            "http://github.com/zzusec/TermYes/releases/tag/v1.6.18",
            "https://github.com.evil.test/zzusec/TermYes/releases/tag/v1.6.18",
            "https://github.com:8443/zzusec/TermYes/releases/tag/v1.6.18",
            "https://user@github.com/zzusec/TermYes/releases/tag/v1.6.18",
            "https://github.com/other/TermYes/releases/tag/v1.6.18",
            "https://github.com/zzusec/TermYes/releases/latest",
            "https://github.com/zzusec/TermYes/releases/tag/v1.6.18-beta",
            "https://github.com/zzusec/TermYes/releases/tag/v1.6.18/extra",
            "https://github.com/zzusec/TermYes/releases/tag/v1%2E6%2E18",
            "https://github.com/zzusec/TermYes/releases/tag/v1.6.18?download=1",
            "https://github.com/zzusec/TermYes/releases/tag/v1.6.18#details"
        ] {
            expect(GitHubReleaseLocation(redirectedURL: URL(string: invalidURL)!) == nil, "should reject \(invalidURL)")
        }
        print("Release location tests passed.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
