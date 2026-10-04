import Foundation

// MARK: - Claude desktop app usage
//
// The Claude desktop app fetches claude.ai/api/organizations/<org>/usage on its own and
// keeps the response in its Chromium HTTP cache. Coucou only reads that cached response:
// no token, no cookie and no network call. This gives plan usage for people who use
// Claude Code from the desktop app, where the status line relay never runs.

enum ClaudeDesktopUsage {

    static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: cacheDir.path)
    }

    /// Newest cached usage response, parsed. nil if none is found or it can't be decoded.
    static func read() -> PlanUsage? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let dated: [(URL, Date)] = files.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let d = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
            return (url, d)
        }.sorted { $0.1 > $1.1 }

        for (url, date) in dated.prefix(5000) {
            guard let entry = readEntry(url), isUsageKey(entry.key) else { continue }
            guard let json = decodeBody(entry.body, zstd: entry.zstd),
                  let usage = parse(json, updatedAt: date) else { continue }
            return usage
        }
        return nil
    }

    // MARK: Chromium simple cache entry

    private static let entryMagic: UInt64 = 0xfcfb6d1ba7725c30
    private static let eofMagic: UInt64 = 0xf4fa6f45970d41d8

    /// Splits a simple-cache `_0` file into its key and its body (stream 1).
    private static func readEntry(_ url: URL) -> (key: String, body: Data, zstd: Bool)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 24 else { return nil }
        func u64(_ o: Int) -> UInt64 { data.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        func u32(_ o: Int) -> UInt32 { data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard u64(0) == entryMagic else { return nil }
        let keyLen = Int(u32(12))
        let bodyStart = 24 + keyLen
        guard keyLen > 0, keyLen < 4096, bodyStart < data.count,
              let key = String(data: data.subdata(in: 24..<bodyStart), encoding: .utf8) else { return nil }
        // Cheap reject before searching for the body end
        guard isUsageKey(key) else { return (key, Data(), false) }
        var eofBytes = eofMagic.littleEndian
        let marker = Data(bytes: &eofBytes, count: 8)
        guard let eof = data.range(of: marker, in: bodyStart..<data.count) else { return nil }
        let body = data.subdata(in: bodyStart..<eof.lowerBound)
        let headers = data.subdata(in: eof.upperBound..<data.count)
        let zstd = headers.range(of: Data("content-encoding:zstd".utf8)) != nil
        return (key, body, zstd)
    }

    private static let usageKeyRegex = try! NSRegularExpression(
        pattern: #"^(1/0/)?https://claude\.ai/api/organizations/[0-9a-fA-F-]+/usage(\?|$)"#)

    static func isUsageKey(_ key: String) -> Bool {
        usageKeyRegex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    // MARK: Body decoding

    private static func decodeBody(_ body: Data, zstd: Bool) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        let raw: Data
        if body.first == UInt8(ascii: "{") {
            raw = body
        } else if zstd, let out = zstdDecompress(body) {
            raw = out
        } else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
    }

    /// macOS has no built-in zstd, so use the zstd tool or a Python 3.14+ when present.
    private static func zstdDecompress(_ data: Data) -> Data? {
        let fm = FileManager.default
        let tools: [(String, [String])] = [
            ("/opt/homebrew/bin/zstd", ["-d", "-c", "-q"]),
            ("/usr/local/bin/zstd", ["-d", "-c", "-q"]),
        ] + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].map {
            ($0, ["-c", "import sys,compression.zstd as z;sys.stdout.buffer.write(z.decompress(sys.stdin.buffer.read()))"])
        }
        for (path, args) in tools where fm.isExecutableFile(atPath: path) {
            if let out = run(path, args, input: data), !out.isEmpty { return out }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String], input: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    // MARK: JSON → PlanUsage

    static func parse(_ json: [String: Any], updatedAt: Date) -> PlanUsage? {
        let fiveHour = window(json["five_hour"])
        let sevenDay = window(json["seven_day"])
        var scoped: [ScopedPlanWindow] = []
        for limit in json["limits"] as? [[String: Any]] ?? [] {
            guard (limit["kind"] as? String) == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let pct = number(limit["percent"]),
                  let resets = date(limit["resets_at"]) else { continue }
            scoped.append(ScopedPlanWindow(name: name,
                                           window: PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: resets)))
        }
        guard fiveHour != nil || sevenDay != nil || !scoped.isEmpty else { return nil }
        return PlanUsage(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt,
                         scoped: scoped.isEmpty ? nil : scoped)
    }

    private static func window(_ raw: Any?) -> PlanWindow? {
        guard let d = raw as? [String: Any],
              let pct = number(d["utilization"]),
              let resets = date(d["resets_at"]) else { return nil }
        return PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: resets)
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// Parses "2026-10-04T15:59:59.574505+00:00" (microseconds are dropped).
    private static func date(_ v: Any?) -> Date? {
        guard var s = v as? String else { return nil }
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            s.removeSubrange(dot..<tz)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Poller

@MainActor
final class ClaudeDesktopUsagePoller {
    static let shared = ClaudeDesktopUsagePoller()
    private var timer: Timer?
    private var reading = false

    func start() {
        guard ClaudeDesktopUsage.isAvailable, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ClaudeDesktopUsagePoller.shared.refresh() }
        }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let usage = ClaudeDesktopUsage.read()
            await MainActor.run {
                ClaudeDesktopUsagePoller.shared.reading = false
                guard let usage else { return }
                let state = AppState.shared
                // Keep a newer status line reading; otherwise take the desktop app's.
                if let current = state.claudePlanUsage, current.updatedAt > usage.updatedAt { return }
                if state.claudePlanUsage != usage { state.claudePlanUsage = usage }
            }
        }
    }
}
