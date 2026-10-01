import CryptoKit
import Foundation

/// A task as the local server's /api/work snapshot reports it.
struct BoardTask {
    let id: String
    let title: String
    let status: String
    let revision: String
    let focusOn: String?
    let dueOn: String?
    let priority: String?
    let context: String

    var isOpen: Bool { !["done", "dropped"].contains(status) }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let title = d["title"] as? String, let revision = d["revision"] as? String else { return nil }
        self.id = id
        self.title = title
        self.revision = revision
        status = d["status"] as? String ?? ""
        focusOn = d["focus_on"] as? String
        dueOn = d["due_on"] as? String
        priority = d["priority"] as? String
        context = d["context"] as? String ?? ""
    }
}

/// Today's view of the task list for the card and "what's on my plate?".
struct Agenda {
    var today = ""
    var focus: [BoardTask] = []
    var due: [BoardTask] = []
    var approvals: [BoardTask] = []
    var inbox = 0
    var fetchedAt = Date.distantPast
    var error: String?

    var summary: String {
        if let error { return error }
        var parts = ["\(focus.count) in focus today"]
        if !due.isEmpty { parts.append("\(due.count) due or overdue") }
        if !approvals.isEmpty { parts.append("\(approvals.count) waiting on your approval") }
        if inbox > 0 { parts.append("\(inbox) in the inbox") }
        return parts.joined(separator: " · ")
    }
}

/// Reads and updates tasks through the local server. Every change is a
/// status edit on one task with its current revision, so a stale view can never overwrite work.
final class TaskBoard {
    let url: URL

    init(url: URL) { self.url = url }

    func snapshot() async throws -> (today: String, tasks: [BoardTask]) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["tasks"] as? [[String: Any]]
        else { throw EngineError.message("The task list did not answer") }
        return (json["today"] as? String ?? "", list.compactMap(BoardTask.init))
    }

    func agenda() async -> Agenda {
        do {
            let (today, tasks) = try await snapshot()
            let open = tasks.filter(\.isOpen)
            var a = Agenda(today: today)
            a.focus = open.filter { $0.focusOn == today }
            a.due = open.filter { t in (t.dueOn.map { $0 <= today } ?? false) && t.focusOn != today }
                .sorted { ($0.dueOn ?? "") < ($1.dueOn ?? "") }
            a.approvals = open.filter { $0.status == "approval" }
            a.inbox = open.filter { $0.status == "inbox" }.count
            a.fetchedAt = Date()
            return a
        } catch {
            var a = Agenda()
            a.error = "The server is offline, so tasks can't be read."
            return a
        }
    }

    /// Sets one task's status. Returns an error message, or nil on success.
    func setStatus(_ task: BoardTask, to status: String) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": task.id, "based_on": task.revision,
            "request_id": "voice-edit-\(UUID().uuidString.lowercased())",
            "changes": ["status": status],
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return nil }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "The task list refused the change"
        } catch {
            return "The server is offline"
        }
    }

    /// Finds the task a voice capture created: the server derives its id from the request id
    /// ("t-" plus the first 12 hex digits of the SHA-256), and the context carries the request id too.
    func task(forCapture requestID: String) async -> BoardTask? {
        guard let (_, tasks) = try? await snapshot() else { return nil }
        let digest = SHA256.hash(data: Data(requestID.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "t-" + digest.prefix(12)
        return tasks.first { $0.id == id } ?? tasks.first { $0.context.contains(requestID) }
    }

    /// Best open task for "done with the invoice call": word overlap with the title.
    func bestMatch(for query: String) async -> (BoardTask, Double)? {
        guard let (_, tasks) = try? await snapshot() else { return nil }
        let stop: Set<String> = ["the", "a", "an", "to", "with", "and", "for", "of", "on", "about", "my", "i", "im", "done",
                                 "finished", "complete", "completed", "mark", "task", "that", "this", "is", "it", "call"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !stop.contains($0) })
        }
        let q = words(query)
        guard !q.isEmpty else { return nil }
        let scored = tasks.filter(\.isOpen).map { t -> (BoardTask, Double) in
            let w = words(t.title)
            let hits = Double(q.intersection(w).count)
            // Prefix matches catch "invoice" vs "invoices" and "Sam's" vs "Sam".
            let fuzzy = Double(q.filter { qw in !w.contains(qw) && w.contains { $0.hasPrefix(qw.prefix(4)) } }.count) * 0.6
            return (t, (hits + fuzzy) / Double(q.count) + (t.focusOn != nil ? 0.05 : 0))
        }
        return scored.max { $0.1 < $1.1 }.flatMap { $0.1 >= 0.5 ? $0 : nil }
    }
}
