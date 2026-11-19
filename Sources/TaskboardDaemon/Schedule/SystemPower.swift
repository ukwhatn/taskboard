import Foundation
import IOKit

/// Mac が完全に起きているか。ふたを閉じたスリープの間も、macOS は短く起きる（DarkWake）。その間は画面が無く、
/// ネットワークも途切れ途切れで、数秒〜45 秒でまた眠る
public enum SystemPower {
    /// IOPMrootDomain の「System Capabilities」にグラフィックのビット（kIOPMSystemCapabilityGraphics）があるか。
    /// DarkWake は CPU とネットワークだけ（`pmset -g log` の [CDNP]）、完全に起きると画面と音も付く（[CDNVA]）。
    /// 画面だけが消えている間（ディスプレイのスリープ）はビットが残る。読めなければ起きているとみなす（起こさないままにしない）
    public static func isFullWake() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return true }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return true
        }
        return value.uint32Value & graphicsCapability != 0
    }

    /// IOPMPrivate.h の kIOPMSystemCapabilityGraphics（公開ヘッダに無い）
    static let graphicsCapability: UInt32 = 0x2
}
