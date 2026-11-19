import Foundation
import Testing

@testable import TaskboardKit

@Suite("送れなかった発言の自動の送り直し")
struct OutgoingRetryTests {
    @Test("つながらなかった失敗（URLError・接続の切れ・5xx）だけ送り直す。daemon が断った・認証・4xx は送り直さない")
    func transient() {
        #expect(OutgoingRetry.isTransient(URLError(.notConnectedToInternet)))
        #expect(OutgoingRetry.isTransient(URLError(.timedOut)))
        #expect(OutgoingRetry.isTransient(SessionSourceError.disconnected))
        #expect(OutgoingRetry.isTransient(SessionSourceError.httpStatus(502)))
        #expect(OutgoingRetry.isTransient(SessionSourceError.httpStatus(503)))
        #expect(!OutgoingRetry.isTransient(SessionSourceError.httpStatus(404)))
        #expect(!OutgoingRetry.isTransient(SessionSourceError.unauthorized))
        #expect(!OutgoingRetry.isTransient(SessionSourceError.forbidden))
        #expect(!OutgoingRetry.isTransient(SessionSourceError.rejected(DaemonRejection(status: 409, message: "止まっている", code: nil, params: [:]))))
        #expect(!OutgoingRetry.isTransient(CancellationError()))
    }

    @Test("待ちは 1・2・4・8・16・30 秒と延ばし、30 秒をもう 1 回。合わせて 2 分を超えない")
    func delays() {
        var waited: [Int] = []
        var attempt = 0
        while let delay = OutgoingRetry.delay(afterFailure: attempt) {
            waited.append(Int(delay.components.seconds))
            attempt += 1
        }
        #expect(waited == [1, 2, 4, 8, 16, 30, 30])
        #expect(waited.reduce(0, +) <= 120)
    }
}
