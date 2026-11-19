import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// MetricKit の止まりの診断（`MXCallStackTree.jsonRepresentation()` の形）を、daemon へ送る記録にする
@Suite struct HangDiagnosticsTests {
    private func frame(_ binary: String, _ offset: Int, samples: Int = 10, sub: [[String: Any]] = []) -> [String: Any] {
        ["binaryUUID": "00000000-0000-0000-0000-000000000000", "binaryName": binary, "offsetIntoBinaryTextSegment": offset, "sampleCount": samples,
         "address": 4_294_967_296 + offset, "subFrames": sub]
    }

    /// 根から 1 本につないだ枠
    private func chain(_ frames: [(String, Int)]) -> [String: Any] {
        frames.reversed().reduce(into: [String: Any]()) { child, item in
            child = frame(item.0, item.1, sub: child.isEmpty ? [] : [child])
        }
    }

    private func tree(_ stacks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["callStackPerThread": true, "callStacks": stacks])
    }

    @Test("止まりの元のスレッドを、根から標本の多い枝をたどって並べる")
    func followsAttributedThreadAndHeaviestBranch() throws {
        let other = ["threadAttributed": false, "callStackRootFrames": [frame("libsystem_kernel.dylib", 1)]] as [String: Any]
        let main = [
            "threadAttributed": true,
            "callStackRootFrames": [
                frame("SwiftUICore", 0x1234, samples: 30, sub: [frame("Taskboard", 0xff, samples: 25), frame("UIKitCore", 0x10, samples: 5)]),
                frame("CoreFoundation", 0x20, samples: 2),
            ],
        ] as [String: Any]
        #expect(HangDiagnostics.frames(callStackTree: try tree([other, main]), appBinary: "Taskboard") == ["SwiftUICore+0x1234", "Taskboard+0xff"])
    }

    @Test("先頭の 25 個の後はアプリの枠だけを、合わせて 40 個まで残す")
    func keepsAppFramesBeyondLeading() throws {
        let deep = (0..<60).map { n in n % 3 == 0 ? ("Taskboard", n) : ("SwiftUI", n) }
        let frames = HangDiagnostics.frames(callStackTree: try tree([["threadAttributed": true, "callStackRootFrames": [chain(deep)]]]), appBinary: "Taskboard")
        let expected = (0..<25).map { n in n % 3 == 0 ? "Taskboard+0x\(String(n, radix: 16))" : "SwiftUI+0x\(String(n, radix: 16))" }
            + stride(from: 27, to: 60, by: 3).map { "Taskboard+0x\(String($0, radix: 16))" }
        #expect(frames == Array(expected.prefix(40)))
        #expect(frames.count == 36)
    }

    @Test("読めない木は枠なしにし、止まりの記録は残す。同じ診断の id は同じ")
    func toleratesBrokenTree() throws {
        #expect(HangDiagnostics.frames(callStackTree: Data("not json".utf8), appBinary: "Taskboard").isEmpty)
        #expect(HangDiagnostics.frames(callStackTree: try tree([]), appBinary: "Taskboard").isEmpty)
        let values = HangDiagnostics.Values(
            durationMS: 3_500, end: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "build 1", osVersion: "iPhone OS 26.0 (23A1)",
            callStackTree: Data("{}".utf8))
        let report = HangDiagnostics.report(values, appBinary: "Taskboard")
        #expect(report.kind == .hang)
        #expect(report.durationMS == 3_500)
        #expect(report.frames.isEmpty)
        #expect(report.id.hasPrefix("hang-") && report.id.count == 21)
        #expect(HangDiagnostics.report(values, appBinary: "Taskboard").id == report.id)
        var later = values
        later.durationMS = 3_600
        #expect(HangDiagnostics.report(later, appBinary: "Taskboard").id != report.id)
        #expect(report.violation == nil, "daemon が受け付ける形")
    }
}
