import Darwin
import Foundation

/// 同じユーザーのプロセスの表（sysctl の `KERN_PROC`・`KERN_PROCARGS2`）。前の daemon・host が残したプロセスを、pid の使い回しと取り違えずに見つけるのに使う
enum ProcessTable {
    struct Entry: Equatable {
        var pid: pid_t
        var ppid: pid_t
        var pgid: pid_t
        /// プロセスの開始時刻（エポックからのマイクロ秒）
        var startedAt: Int64
    }

    /// `KERN_PROCARGS2` の中身
    struct Arguments: Equatable {
        var executable: String
        var argv: [String]
        var environment: [String: String]
    }

    /// 表を読む同期の処理を、協調プールの外のスレッドで動かす。全部のプロセスの `arguments(of:)` を読むと、負荷の高い Mac では 1 秒を超え、
    /// その間プールのスレッドを持ったままだと、同じプロセスのほかの Task が止まる
    static func offPool<T: Sendable>(_ read: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: read()) }
        }
    }

    static func processes(uid: uid_t) -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        let stride = MemoryLayout<kinfo_proc>.stride
        // 測ってから読むまでにプロセスが増えると ENOMEM になるので、余白を取って数回やり直す
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            size += size / 8 + stride * 16
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result == 0 { return buffer.prefix(size / stride).map(entry) }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// 1 つのプロセス。無ければ nil
    static func process(_ pid: pid_t) -> Entry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return entry(info)
    }

    /// 同じユーザーの別プロセスの実行ファイル・argv・env。読めなければ nil（OS の実行ファイルの env は読めない）
    static func arguments(of pid: pid_t) -> Arguments? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var limitMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitMib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &length, nil, 0) }
        guard result == 0 else { return nil }
        return parse(procargs: buffer.prefix(length))
    }

    /// `KERN_PROCARGS2` の中身：argc（int32）・実行ファイルのパス・NUL の詰め物・argv の argc 個・env。
    /// env の後ろに `executable_path=` などの apple の文字列が続くことがあるので、同じ名前は先に出たほうを取る。argv が途中で切れていれば env は空
    static func parse(procargs: some Collection<UInt8>) -> Arguments? {
        let bytes = Array(procargs)
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        var index = 4
        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
            let text = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end + 1
            return text
        }
        var parsed = Arguments(executable: nextString() ?? "", argv: [], environment: [:])
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc {
            guard let argument = nextString() else { return parsed }
            parsed.argv.append(argument)
        }
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if parsed.environment[key] == nil { parsed.environment[key] = String(entry[entry.index(after: equals)...]) }
        }
        return parsed
    }

    private static func entry(_ info: kinfo_proc) -> Entry {
        let started = info.kp_proc.p_un.__p_starttime
        return Entry(
            pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid, pgid: info.kp_eproc.e_pgid,
            startedAt: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec))
    }
}
