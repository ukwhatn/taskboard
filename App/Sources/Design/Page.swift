import SwiftUI
import TaskboardKit

/// 縦にスクロールする画面。左右に `pageInset`、節どうしに `Space.section` を取る。`maxWidth` を渡すと中央に寄せる
struct Page<Content: View>: View {
    var maxWidth: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.pageInset) private var inset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) { content }
                .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                // 横の余白は contentMargins にしない（ウィンドウの外で描く snapshot で、初めの位置の余白が隠れた）
                .padding(.horizontal, inset)
        }
        .contentMargins(.vertical, Space.section, for: .scrollContent)
    }
}

/// 節。見出しと右端の操作、その下に中身
struct PageSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(title).textRole(.sectionTitle)
                Spacer(minLength: Space.row)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// 囲み。置かれた枠の幅いっぱいに広がり、内側に `Space.card` を取る
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
