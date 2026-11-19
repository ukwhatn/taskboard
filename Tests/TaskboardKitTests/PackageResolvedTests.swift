import Foundation
import Testing

/// SwiftPM（根の Package.resolved）と Xcode（xcworkspace の Package.resolved）が依存の版を別々に持つ（docs/development.md「依存の版」）
@Suite struct PackageResolvedTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let swiftPM = root.appending(path: "Package.resolved")
    static let xcode = root.appending(path: "App/Taskboard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

    private func pins(_ file: URL) throws -> [String: [String: String]] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let pins = try #require(object["pins"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: pins.compactMap { pin in
            guard let identity = pin["identity"] as? String, let state = pin["state"] as? [String: String] else { return nil }
            return (identity, state)
        })
    }

    @Test("Xcode の分があり、SwiftPM の分の package はどれも Xcode の分に同じ版と revision で載っている")
    func sharedPinsMatch() throws {
        // Xcode の分が無いと、Xcode は根の Package.resolved に自分の依存を書き戻す
        #expect(FileManager.default.fileExists(atPath: Self.xcode.path), "\(Self.xcode.path) が無い")
        let swiftPM = try pins(Self.swiftPM)
        let xcode = try pins(Self.xcode)
        for (identity, state) in swiftPM.sorted(by: { $0.key < $1.key }) {
            #expect(xcode[identity] == state, "\(identity): SwiftPM \(state)、Xcode \(xcode[identity].map { "\($0)" } ?? "無し")")
        }
    }
}
