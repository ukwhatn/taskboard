#if os(iOS)
import SwiftUI
import TaskboardKit
import VisionKit

/// アプリ内のスキャナ。Taskboard の QR コードだけを受け取る（標準のカメラで読ませないのは、中身に Access の secret があるため）
struct QRScannerScreen: View {
    let onFound: (PairingPayload) -> Void
    let onCode: () -> Void
    let onCancel: () -> Void
    @State private var note: String?
    @State private var unavailable: String?

    /// 機器が対応していて、カメラの利用が許されている（初回の許可前も true）
    @MainActor static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let unavailable {
                    ContentUnavailableView {
                        Label("カメラを使えません", systemImage: "camera.badge.ellipsis")
                    } description: {
                        Text(unavailable)
                    } actions: {
                        Button("コードで追加", action: onCode).buttonStyle(.borderedProminent)
                    }
                } else {
                    Scanner(
                        onText: { text in
                            if let payload = PairingPayload.decode(text) {
                                onFound(payload)
                            } else {
                                note = String(localized: "TaskboardのQRコードではありません。")
                            }
                        },
                        onUnavailable: { unavailable = $0 }
                    )
                    .ignoresSafeArea()
                    Text(note ?? String(localized: "追加するMacに表示したQRコードにカメラを向けてください。"))
                        .font(.callout)
                        .padding(.horizontal, Space.block)
                        .padding(.vertical, Space.row)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, Space.section)
                        // 違う QR コードの知らせは、少しおいて案内の文に戻す
                        .task(id: note) {
                            guard note != nil else { return }
                            try? await Task.sleep(for: .seconds(3))
                            note = nil
                        }
                }
            }
            .navigationTitle("QRコードの読み取り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: onCancel) }
                ToolbarItem(placement: .primaryAction) { Button("コードで追加", action: onCode) }
            }
        }
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onText: (String) -> Void
    let onUnavailable: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // 画面に載ってから始める（載る前の startScanning は notAvailable になる）
        guard !context.coordinator.started else { return }
        context.coordinator.started = true
        DispatchQueue.main.async {
            do {
                try controller.startScanning()
            } catch {
                onUnavailable(Coordinator.reason(error))
            }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, onUnavailable: onUnavailable) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: (String) -> Void
        let onUnavailable: (String) -> Void
        var started = false

        init(onText: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {
            self.onText = onText
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    onText(text)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onUnavailable(Self.reason(error))
        }

        static func reason(_ error: Error) -> String {
            switch error as? DataScannerViewController.ScanningUnavailable {
            case .cameraRestricted: String(localized: "カメラへのアクセスが許可されていません。設定アプリの［Taskboard］でカメラをオンにしてください。")
            case .unsupported: String(localized: "このデバイスはQRコードの読み取りに対応していません。［コードで追加］を使ってください。")
            default: String(localized: "読み取りを開始できませんでした。［コードで追加］を使ってください。")
            }
        }
    }
}
#endif
