import Testing

@testable import taskboard

@Suite("install-launchd：plist に書く PATH")
struct InstallLaunchdTests {
    let home = "/Users/u"

    @Test("mise の版ごとの置き場を外し、最初に外した位置に shims を置く（後ろにあった shims は前へ移る）")
    func replacesInstallsWithShims() {
        let path = [
            "/Users/u/google-cloud-sdk/bin",
            "/Users/u/.local/share/mise/installs/go/1.25.5/bin",
            "/Users/u/.local/share/mise/installs/node/24.16.0/bin",
            "/Users/u/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/usr/bin",
        ].joined(separator: ":")
        #expect(
            InstallLaunchd.launchdPath(path, home: home)
                == "/Users/u/google-cloud-sdk/bin:/Users/u/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin")
    }

    @Test("shims が先にあればその位置のまま。mise が無い PATH は重複と空の要素を除くほか変えない")
    func keepsOtherEntries() {
        #expect(
            InstallLaunchd.launchdPath("/Users/u/.local/share/mise/shims:/Users/u/.local/share/mise/installs/node/24.22.1/bin:/usr/bin", home: home)
                == "/Users/u/.local/share/mise/shims:/usr/bin")
        #expect(InstallLaunchd.launchdPath("/opt/homebrew/bin::/usr/bin:/opt/homebrew/bin", home: home) == "/opt/homebrew/bin:/usr/bin")
        #expect(InstallLaunchd.launchdPath("", home: home) == "")
    }

    @Test("別のユーザーの mise の置き場と、名前が似ているだけの場所は外さない")
    func onlyOwnMiseInstalls() {
        let path = "/Users/other/.local/share/mise/installs/node/24.16.0/bin:/Users/u/.local/share/mise-installs/bin"
        #expect(InstallLaunchd.launchdPath(path, home: home) == path)
    }
}
