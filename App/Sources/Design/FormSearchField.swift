import SwiftUI

/// シートの Form の頭に置く検索の欄。grouped Form は TextField の題をラベルにするので、ラベルを隠すと placeholder も枠も無い欄になる（印と prompt で欄と分かるようにする）
struct FormSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: Space.row) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("検索", text: $query, prompt: Text("検索"))
                .labelsHidden()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }
}
