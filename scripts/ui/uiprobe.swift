// 実ウィンドウの確認の道具（docs/ui-system.md「確かめ方」）。scripts/ui/*.sh が swiftc でビルドして使う。
// 読み上げの木と窓の一覧を読み、マウスもキーボードも動かさない。押す・送るはアプリの debug の口（/click・/cursor）で行う。
// シートの中のボタンは /click では押せない（後ろにある窓の最初のクリックは窓を前に出すだけで、ボタンに届かない）ので、press で読み上げの木から押す。
//
//   uiprobe window <pid> [題]        窓の番号と位置（screencapture -l に渡す番号、画面座標の x y w h）。題を渡すと、題がそれで始まる窓
//   uiprobe cards <pid>              全体のボードのカードの「マシン/番号 x y w h」と、ボードの見えている範囲「ax ay aw ah」
//                                    （サイドバーの境目の右、題の帯 52pt の下。面の読み上げの枠は描かれた位置と合わなかったので使わない）
//   uiprobe elements <pid>           読み上げの木の要素を「深さ 役割 名前 x y w h」で出す（押す位置を探すとき）
//   uiprobe press <pid> <名前>       名前がそれと同じ要素のうち、木の中で最後に出たもの（シートのボタンは親の窓のボタンより後に出る）を押す
//
// cards と elements にはアクセシビリティの許可（システム設定 > プライバシーとセキュリティ > アクセシビリティ）が要る
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func window(pid: Int32, title: String? = nil) -> (id: Int, frame: CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let title, (w[kCGWindowName as String] as? String)?.hasPrefix(title) != true { continue }
        guard let id = w[kCGWindowNumber as String] as? Int, let bounds = w[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds)
        else { continue }
        return (id, frame)
    }
    return nil
}

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute), let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position, .cgPoint, &point)
    AXValueGetValue(size, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func texts(_ element: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 3 else { return [] }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    var found: [String] = []
    for child in children {
        if let role: String = attribute(child, kAXRoleAttribute), role == kAXStaticTextRole as String, let value: String = attribute(child, kAXValueAttribute) {
            found.append(value)
        }
        found += texts(child, depth: depth + 1)
    }
    return found
}

/// カード: identifier が `task:<マシン>/<番号>` の要素（TaskCardButton）
func cards(in element: AXUIElement, into found: inout [(String, CGRect)], depth: Int = 0) {
    guard depth < 40 else { return }
    if (attribute(element, kAXRoleAttribute) as String?) == kAXButtonRole as String,
        let identifier: String = attribute(element, kAXIdentifierAttribute), identifier.hasPrefix("task:"), let rect = frame(element)
    {
        found.append((String(identifier.dropFirst("task:".count)), rect))
        return
    }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    for child in children { cards(in: child, into: &found, depth: depth + 1) }
}

/// サイドバーの境目（最初の AXSplitter）
func splitter(in element: AXUIElement, depth: Int = 0) -> CGRect? {
    guard depth < 8 else { return nil }
    if (attribute(element, kAXRoleAttribute) as String?) == kAXSplitterRole as String { return frame(element) }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    for child in children { if let found = splitter(in: child, depth: depth + 1) { return found } }
    return nil
}

/// 読み上げの名前。説明 → 題 → 値の順に、空でない最初のもの
func label(_ element: AXUIElement) -> String {
    for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
        if let value: String = attribute(element, name), !value.isEmpty { return value.replacingOccurrences(of: "\n", with: " ") }
    }
    return ""
}

func dump(_ element: AXUIElement, depth: Int = 0) {
    guard depth < 40 else { return }
    let role: String = attribute(element, kAXRoleAttribute) ?? "?"
    let rect = frame(element) ?? .zero
    print(depth, role, label(element).isEmpty ? "-" : label(element), Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height), separator: "\t")
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    for child in children { dump(child, depth: depth + 1) }
}

func matches(_ element: AXUIElement, name: String, into found: inout [AXUIElement], depth: Int = 0) {
    guard depth < 40 else { return }
    if label(element) == name { found.append(element) }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    for child in children { matches(child, name: name, into: &found, depth: depth + 1) }
}

switch args.count > 1 ? args[1] : "" {
case "window":
    guard args.count > 2, let pid = Int32(args[2]), let w = window(pid: pid, title: args.count > 3 ? args[3] : nil) else { fail("ウィンドウが見つからない") }
    print(w.id, Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height))
case "cards":
    guard args.count > 2, let pid = Int32(args[2]) else { fail("pid が要る") }
    guard AXIsProcessTrusted() else { fail("アクセシビリティの許可が無い") }
    let app = AXUIElementCreateApplication(pid)
    let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
    for window in windows {
        guard let bounds = frame(window) else { continue }
        let left = splitter(in: window)?.maxX ?? bounds.minX
        let area = CGRect(x: left, y: bounds.minY + 52, width: bounds.maxX - left, height: bounds.height - 52)
        var found: [(String, CGRect)] = []
        cards(in: window, into: &found)
        for (key, rect) in found {
            print(key, Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height), Int(area.minX), Int(area.minY), Int(area.width), Int(area.height))
        }
    }
case "elements":
    guard args.count > 2, let pid = Int32(args[2]) else { fail("pid が要る") }
    guard AXIsProcessTrusted() else { fail("アクセシビリティの許可が無い") }
    let windows: [AXUIElement] = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
    for window in windows { dump(window) }
case "press":
    guard args.count > 3, let pid = Int32(args[2]) else { fail("pid と名前が要る") }
    guard AXIsProcessTrusted() else { fail("アクセシビリティの許可が無い") }
    var found: [AXUIElement] = []
    for window in (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []) as [AXUIElement] {
        matches(window, name: args[3], into: &found)
    }
    guard let target = found.last else { fail("「\(args[3])」が見つからない") }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { fail("「\(args[3])」を押せない") }
    print("pressed", args[3])
default:
    fail("使い方: uiprobe window|cards|elements|press <pid>")
}
