import SwiftUI
import TaskboardKit

/// 接続先の一覧。状態（接続済み・トークンの不一致・Access の拒否・切断）、並べ替え、表示の切り替え、資格情報の編集、削除。
/// その下に、接続先ごとの端末（iPhone・iPad）の一覧
struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ConnectionDraft?
    @State private var deleting: SavedConnection?
    /// 削除はできたが、端末の登録を解除できなかったときの知らせ
    @State private var notice: UserFacingError?

    var body: some View {
        let machines = model.orderedAllMachines
        Form {
            if let notice {
                Section {
                    Banner(kind: .error, message: notice.text) { self.notice = nil }
                }
            }
            Section {
                ForEach(Array(machines.enumerated()), id: \.element.id) { index, entry in
                    row(entry.id, state: entry.state, index: index, count: machines.count)
                }
                .onMove { model.moveAllMachines(from: $0, to: $1) }
                Button("接続先を追加", systemImage: "plus") { model.addingConnection = .menu }
            } header: {
                Text("接続先")
            } footer: {
                if model.connections.isEmpty {
                    Text("ほかのMacの接続先はありません。追加すると、そのMacの案件とセッションが表示されます。")
                }
            }
            ForEach(machines.filter { showsDevices($0.id, state: $0.state) }, id: \.id) { entry in
                DeviceList(fleetID: entry.id, title: machines.count > 1 ? String(localized: "\(model.machineName(fleetID: entry.id, state: entry.state))のデバイス") : String(localized: "デバイス"))
            }
            ForEach(machines.filter { $0.state.connected }, id: \.id) { entry in
                CodexSection(fleetID: entry.id, title: machines.count > 1 ? String(localized: "\(model.machineName(fleetID: entry.id, state: entry.state))のCodex") : "Codex")
            }
        }
        .formStyle(.grouped)
        .settingsContentWidth()
        .sheet(item: $editing) { draft in
            ConnectionForm(draft: draft)
        }
        .sheet(isPresented: Binding(get: { model.addingConnection != nil }, set: { if !$0 { model.addingConnection = nil } })) {
            AddConnectionSheet(mode: model.addingConnection ?? .menu, onToken: { editing = ConnectionDraft() })
        }
        .sheet(item: Bindable(model).pairingSheet) { target in
            PairingSheet(fleetID: target.fleetID)
        }
        .background {
            // 1 つの view に sheet を重ねると片方しか出ないことがあるので、読んだ QR の確認は別の view に付ける
            Color.clear.sheet(item: Bindable(model).pairingOffer) { offer in
                AddConnectionSheet(mode: .confirm(offer.payload))
            }
        }
        .confirmationDialog("接続先の削除", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { connection in
            Button("削除", role: .destructive) { delete(connection) }
            Button("キャンセル", role: .cancel) {}
        } message: { connection in
            if connection.pairedDeviceID == nil {
                Text("「\(connection.name)」を削除しますか？　この操作は元に戻せません。")
            } else {
                Text("「\(connection.name)」を削除しますか？　接続先のMacで、このデバイスの登録も解除します。この操作は元に戻せません。")
            }
        }
    }

    /// 端末の一覧を出す接続先。daemon のトークンで接続しているときだけ（端末のトークンでは daemon が一覧を断る）
    private func showsDevices(_ fleetID: String, state: MachineState?) -> Bool {
        state?.connected == true && model.showsDeviceSection(fleetID: fleetID)
    }

    private func row(_ fleetID: String, state: MachineState?, index: Int, count: Int) -> ConnectionRow {
        let connection = model.connections.first { $0.fleetID == fleetID }
        return ConnectionRow(
            name: connection?.name ?? model.machineName(fleetID: fleetID, state: state),
            // 同じ Mac の接続は URL を出さない（内部のアドレスは利用者の判断に要らない）
            detail: connection?.url.absoluteString,
            state: state,
            paired: connection?.pairedDeviceID != nil,
            hidden: model.hiddenMachines.contains(fleetID),
            menu: ConnectionRow.Menu(
                canMoveUp: index > 0, canMoveDown: index < count - 1,
                move: { model.moveMachine(fleetID, by: $0) },
                setHidden: { model.setMachineHidden(fleetID, $0) },
                edit: connection.map { connection in { editing = ConnectionDraft(connection) } },
                delete: connection.map { connection in { deleting = connection } }))
    }

    private func delete(_ connection: SavedConnection) {
        notice = nil
        Task {
            if await !model.deleteConnectionAndRevoke(id: connection.id) {
                notice = UserFacingError(
                    "「\(connection.name)」を削除しましたが、接続先のMacでこのデバイスの登録を解除できませんでした",
                    remedy: String(localized: "接続先のMacの［設定］>［接続先］で、このデバイスの登録を解除してください"))
            }
        }
    }
}

/// 接続先の 1 行。アイコン・名前・URL・状態と、操作のメニュー
struct ConnectionRow: View {
    let name: String
    let detail: String?
    let state: MachineState?
    /// 端末のトークンで接続している
    var paired = false
    var hidden = false
    /// 設定の接続先の一覧だけ: 並べ替え・表示・編集・削除
    var menu: Menu?

    struct Menu {
        let canMoveUp: Bool
        let canMoveDown: Bool
        let move: (Int) -> Void
        let setHidden: (Bool) -> Void
        var edit: (() -> Void)?
        var delete: (() -> Void)?
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.block) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.inline) {
                    Text(name).textRole(.title).lineLimit(1)
                    if hidden { Chip(text: String(localized: "非表示")) }
                }
                if let detail {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Group {
                    if !status.needsCredentials {
                        Text(status.detail).textRole(.secondary)
                    } else {
                        // 役割の色（secondary）を重ねると、暗い外観で赤が沈んで読めない
                        Text(status.detail).font(.callout).foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let menu { actions(menu) }
        }
        .accessibilityElement(children: .contain)
    }

    private func actions(_ menu: Menu) -> some View {
        SwiftUI.Menu {
            if let edit = menu.edit {
                Button(status.needsCredentials ? "資格情報を入力し直す" : "編集", systemImage: "pencil", action: edit)
            }
            Toggle("画面と通知に表示", isOn: Binding(get: { !hidden }, set: { menu.setHidden(!$0) }))
            Divider()
            Button("上へ移動", systemImage: "arrow.up") { menu.move(-1) }.disabled(!menu.canMoveUp)
            Button("下へ移動", systemImage: "arrow.down") { menu.move(1) }.disabled(!menu.canMoveDown)
            if let delete = menu.delete {
                Divider()
                Button("削除", systemImage: "trash", role: .destructive, action: delete)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .hitTarget()
        .accessibilityLabel("「\(name)」の操作")
    }

    private var status: MachineConnectionStatus { .of(state, paired: paired) }

    /// どれも丸の記号にして幅を揃える（幅が違うと、行ごとに名前の始まりがずれる）
    private var symbol: String {
        switch status {
        case .notConnected: "circle.dashed"
        case .connected, .updatingHost: "checkmark.circle.fill"
        case .connecting, .failed: status.needsCredentials ? "lock.circle.fill" : "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .notConnected: .secondary
        case .connected, .updatingHost: .green
        case .connecting, .failed: status.needsCredentials ? .red : .orange
        }
    }
}

/// 編集中の値。秘密の欄は既存の値を画面に戻さず、空なら「変えない」
struct ConnectionDraft: Identifiable {
    let id: UUID
    let existing: SavedConnection?
    var name = ""
    var url = "https://"
    var token = ""
    var accessID = ""
    var accessSecret = ""

    init() {
        id = UUID()
        existing = nil
    }

    init(_ connection: SavedConnection) {
        id = connection.id
        existing = connection
        name = connection.name
        url = connection.url.absoluteString
        accessID = connection.access?.clientID ?? ""
    }

    /// 足りない欄があれば、入力の仕方を返す
    func build() -> Result<SavedConnection, DraftError> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.message(String(localized: "名前を入力してください。"))) }
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = parsed.scheme, ["http", "https"].contains(scheme), parsed.host() != nil else {
            return .failure(.message(String(localized: "URLは「https://」から入力してください。")))
        }
        let token = self.token.isEmpty ? existing?.token ?? "" : self.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.message(String(localized: "トークンを入力してください。"))) }
        let id = accessID.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.isEmpty ? (existing?.access?.clientID == id ? existing?.access?.clientSecret ?? "" : "") : accessSecret.trimmingCharacters(in: .whitespaces)
        if id.isEmpty != secret.isEmpty { return .failure(.message(String(localized: "Client IDとClient Secretは、両方入力するか両方空にしてください。"))) }
        let access = id.isEmpty ? nil : AccessCredential(clientID: id, clientSecret: secret)
        // token を変えなければ、端末の token のまま（daemon の token に差し替えたときだけ端末の扱いを外す）
        let pairedDeviceID = self.token.isEmpty ? existing?.pairedDeviceID : nil
        return .success(SavedConnection(id: self.id, name: trimmed, url: parsed, token: token, access: access, pairedDeviceID: pairedDeviceID))
    }

    enum DraftError: Error { case message(String) }
}

/// 接続先の追加と編集（トークンで追加する接続先）。削除は一覧の行のメニューから
struct ConnectionForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ConnectionDraft
    @State private var error: String?

    var body: some View {
        let adding = draft.existing == nil
        SheetScaffold(title: adding ? String(localized: "接続先の追加") : String(localized: "接続先の編集"), error: error, onCancel: { dismiss() }) {
            Section {
                LabeledTextField(label: String(localized: "名前（必須）"), text: $draft.name)
                LabeledContentField(String(localized: "URL（必須）")) {
                    TextField("URL（必須）", text: $draft.url)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("接続先のMacで公開しているURLを入力してください。")
            }
            Section {
                LabeledContentField(adding ? String(localized: "トークン（必須）") : String(localized: "トークン")) {
                    SecureField(adding ? "トークン（必須）" : "トークン", text: $draft.token)
                }
            } footer: {
                if adding {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("接続先のMacで、次のファイルに書かれた文字列を入力してください。")
                        Text(verbatim: "~/Library/Application Support/taskboard/token").font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Text("変更しない場合は空欄のままにしてください。")
                }
            }
            AccessFields(id: $draft.accessID, secret: $draft.accessSecret, keepsSecret: draft.existing?.access != nil)
        } actions: {
            Button(adding ? "追加" : "保存", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private func save() {
        switch draft.build() {
        case .failure(.message(let message)):
            error = message
        case .success(let connection):
            do {
                try model.saveConnection(connection)
                dismiss()
            } catch {
                self.error = UserFacingError(draft.existing == nil ? "接続先を追加できませんでした" : "保存できませんでした", error: error)?.text
            }
        }
    }
}
