import Foundation

/// Writes a local HTML page comparing raw speech with the cleaned text.
enum HistoryPage {
    static func write(_ rows: [Dictation]) {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        let items = rows.map { d -> String in
            let changed = d.rawText != d.finalText
            return """
            <article>
              <header><span class="mode \(d.mode)">\(d.mode == "assistant" ? GWConfig.name : "Dictation")</span><span>\(df.string(from: d.createdAt))</span><span>\(esc(d.appName ?? "Unknown app"))</span>
              <span>\(String(format: "%.1f", d.durationSec))s audio · speech \(d.asrMs) ms · cleanup \(d.cleanupMs) ms</span></header>
              <p class="final">\(esc(d.finalText).replacingOccurrences(of: "\n", with: "<br>"))</p>
              \(changed || d.mode == "assistant" ? "<p class=\"raw\"><b>Heard:</b> \(esc(d.rawText))</p>" : "")
              \(d.mode == "assistant" ? "<p class=\"assistant\"><b>\(GWConfig.name):</b> \(esc(d.summary ?? ""))\(d.actionRef.map { $0.hasSuffix(".md") ? " · <code>\(esc($0))</code>" : "" } ?? "")</p>" : "")
              <audio controls preload="none" src="file://\(d.audioPath)"></audio>
            </article>
            """
        }.joined(separator: "\n")

        let words = rows.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(GWConfig.name) Voice History</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { --bg:#f7f6f3; --card:#fff; --ink:#1d1d1f; --muted:#6e6e73; --line:#e5e3de; }
        @media (prefers-color-scheme: dark) { :root { --bg:#161617; --card:#1f1f21; --ink:#f2f2f2; --muted:#9a9aa0; --line:#2c2c2f; } }
        body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, system-ui, sans-serif; }
        main { max-width:760px; margin:0 auto; padding:32px 16px; }
        h1 { font-size:22px; margin:0 0 4px; } .sub { color:var(--muted); margin:0 0 24px; }
        article { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px 16px; margin-bottom:12px; }
        header { display:flex; flex-wrap:wrap; gap:12px; color:var(--muted); font-size:12px; }
        .final { margin:8px 0; white-space:normal; } .raw { color:var(--muted); font-size:13px; margin:6px 0; }
        .assistant { font-size:13px; margin:6px 0; color:#b08a3e; } .mode { font-weight:600; } .mode.assistant { color:#b08a3e; }
        code { font-size:12px; }
        audio { width:100%; height:32px; margin-top:6px; }
        </style></head><body><main>
        <h1>\(GWConfig.name) Voice history</h1>
        <p class="sub">\(rows.count) dictations · \(words) words · stored only on this Mac</p>
        \(items.isEmpty ? "<p>No dictations yet. Hold Right Option and talk.</p>" : items)
        </main></body></html>
        """
        try? html.write(to: Paths.historyPage, atomically: true, encoding: .utf8)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
