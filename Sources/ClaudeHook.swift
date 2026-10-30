import Foundation

/// Hook Claude Code yang dijalankan oleh app ini sendiri: `NotchIsland --claude-hook`.
///
/// Dipanggil Claude Code untuk UserPromptSubmit / PreToolUse / PostToolUse / Notification /
/// Stop / SessionEnd. Menulis status per sesi ke ~/Library/Application Support/NotchIsland/claude/.
/// Tidak pernah mencetak ke stdout (stdout UserPromptSubmit masuk ke konteks Claude) dan selalu exit 0.
enum ClaudeHook {
    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let data = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            handle(data)
        }
        exit(0)
    }

    static func handle(_ data: [String: Any]) {
        guard let sid = data["session_id"] as? String, !sid.isEmpty,
              let event = data["hook_event_name"] as? String else { return }
        let fm = FileManager.default
        let dir = ClaudeMonitor.stateDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(sid).json")

        if event == "SessionEnd" {
            try? fm.removeItem(at: path)
            return
        }

        // Tool paralel bisa memanggil hook bersamaan; kunci supaya tidak saling menimpa.
        let lock = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_WRONLY, 0o644)
        guard lock >= 0 else { return }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN); close(lock) }

        var state = (try? Data(contentsOf: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let now = Date().timeIntervalSince1970
        let cwd = data["cwd"] as? String ?? state["cwd"] as? String ?? ""
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        state["session_id"] = sid
        state["cwd"] = cwd
        state["project"] = project.isEmpty || project == "/" ? "Claude" : project
        state["transcript_path"] = data["transcript_path"] ?? state["transcript_path"] ?? NSNull()
        state["updated_at"] = now
        if let title = data["session_title"] as? String, !title.isEmpty { state["title"] = title }

        // App tempat Claude berjalan (Claude Desktop, VS Code, Terminal, …) — untuk klik dari notch.
        let env = ProcessInfo.processInfo.environment
        if let bundle = env["__CFBundleIdentifier"], !bundle.isEmpty { state["app_bundle"] = bundle }
        if let term = env["TERM_PROGRAM"], !term.isEmpty { state["term_program"] = term }

        switch event {
        case "UserPromptSubmit":
            let prompt = (data["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            state.merge(["state": "working", "prompt": String(prompt.prefix(200)), "started_at": now,
                         "finished_at": NSNull(), "tool": NSNull(), "tool_detail": "", "tool_target": "",
                         "tool_count": 0, "plan": [String](), "message": "", "waiting_kind": NSNull()]) { $1 }
        case "PreToolUse":
            let name = data["tool_name"] as? String ?? ""
            let input = data["tool_input"] as? [String: Any] ?? [:]
            state.merge(["state": "working", "tool": name.components(separatedBy: "__").last ?? name,
                         "tool_detail": toolDetail(input), "tool_target": toolTarget(input),
                         "tool_count": (state["tool_count"] as? Int ?? 0) + 1,
                         "message": "", "waiting_kind": NSNull()]) { $1 }
            if state["started_at"] == nil || state["started_at"] is NSNull { state["started_at"] = now }
            applyPlan(&state, name, input)
        case "PostToolUse":
            // Izin sudah diberikan dan tool selesai → kembali bekerja.
            if state["state"] as? String == "waiting" {
                state.merge(["state": "working", "message": "", "waiting_kind": NSNull()]) { $1 }
            }
        case "Notification":
            let message = String((data["message"] as? String ?? "").prefix(120))
            let kind = data["notification_type"] as? String ?? ""
            // permission_prompt = minta izin tool; idle_prompt = menunggu balasan pengguna.
            let permission = kind.contains("permission") || message.lowercased().contains("permission")
            state.merge(["state": "waiting", "message": message,
                         "waiting_kind": permission ? "permission" : "input"]) { $1 }
        case "Stop":
            state.merge(["state": "done", "finished_at": now, "tool": NSNull(), "tool_detail": ""]) { $1 }
        default:
            break
        }

        if let json = try? JSONSerialization.data(withJSONObject: state) {
            try? json.write(to: path, options: .atomic)
        }
    }

    /// Ringkasan singkat argumen tool untuk ditampilkan di island.
    static func toolDetail(_ input: [String: Any]) -> String {
        for key in ["description", "file_path", "path", "pattern", "url", "query", "command"] {
            guard var value = input[key] as? String, !value.isEmpty else { continue }
            if key == "file_path" || key == "path" {
                let base = URL(fileURLWithPath: value).lastPathComponent
                if !base.isEmpty { value = base }
            }
            return String((value.split(separator: "\n").first.map(String.init) ?? value).prefix(80))
        }
        return ""
    }

    /// Apa persisnya yang akan dilakukan tool — ditampilkan saat Claude minta izin.
    static func toolTarget(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return String((trimmed.split(separator: "\n").first.map(String.init) ?? "").prefix(120))
        }
        for key in ["file_path", "notebook_path", "path"] {
            if let value = input[key] as? String, !value.isEmpty {
                let base = URL(fileURLWithPath: value).lastPathComponent
                return base.isEmpty ? value : base
            }
        }
        return toolDetail(input)
    }

    /// Lacak progress dari task list (TodoWrite di CLI, update_plan di aplikasi desktop).
    static func applyPlan(_ state: inout [String: Any], _ name: String, _ input: [String: Any]) {
        func statuses(_ items: [[String: Any]]) -> [String] { items.map { $0["status"] as? String ?? "pending" } }

        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            state["plan"] = statuses(todos)
            return
        }
        guard name.hasSuffix("update_plan") else { return }
        var plan = state["plan"] as? [String] ?? []
        if let items = input["items"] as? [[String: Any]] {
            plan = statuses(items)
        } else {
            // Indeks 1-based; dicek manual karena `1...plan.count` crash saat plan kosong.
            for case let index as Int in input["done"] as? [Any] ?? [] where index >= 1 && index <= plan.count {
                plan[index - 1] = "completed"
            }
            if input["advance"] as? Bool == true {
                if let i = plan.firstIndex(of: "in_progress") { plan[i] = "completed" }
                if let i = plan.firstIndex(of: "pending") { plan[i] = "in_progress" }
            }
            if let start = input["start"] as? Int, start >= 1, start <= plan.count {
                plan = plan.map { $0 == "in_progress" ? "pending" : $0 }
                plan[start - 1] = "in_progress"
            }
        }
        state["plan"] = plan
    }
}
