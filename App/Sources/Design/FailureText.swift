import SwiftUI

/// カードや入力欄の中に出す失敗の文。シートの失敗は `SheetScaffold` の下の帯に出す
struct FailureText: View {
    let failure: UserFacingError

    init(_ failure: UserFacingError) {
        self.failure = failure
    }

    var body: some View {
        Text(failure.text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }
}
