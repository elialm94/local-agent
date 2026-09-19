import PairCore
import SwiftUI

/// Secondary window: transcript, target, project, actions, latencies, and the
/// raw internals (context sent to the model, tool calls, Cursor prompts).
struct DebugPanelView: View {
    @ObservedObject var model: AppModel
    @State private var typed = ""
    @State private var tab = Tab.session

    enum Tab: String, CaseIterable { case session = "Session", target = "Target", actions = "Actions", internals = "Internals", latency = "Latency", log = "Log" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Group {
                switch tab {
                case .session: session
                case .target: targetView
                case .actions: actionsView
                case .internals: internals
                case .latency: latency
                case .log: log
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composer
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(OrbView.style(for: model.state).color).frame(width: 10, height: 10)
            Text(model.state.rawValue).font(.headline)
            Spacer()
            Label(model.project?.name ?? "no project", systemImage: "folder")
                .foregroundStyle(model.project?.isTrusted == true ? .primary : .orange)
                .help(model.project.map { "\($0.rootPath)\nconfidence \(Int($0.confidence * 100))% via \($0.signals.map(\.rawValue).joined(separator: ", "))" } ?? "Select a project from the menu")
            Text("voice: \(model.voiceProviderName) · agent: \(model.agentProviderName) · reflex: \(model.fastProviderName)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var session: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.transcript) { turn in
                        HStack(alignment: .top) {
                            Text(turn.speaker == .user ? "you" : "grok")
                                .font(.caption.weight(.semibold)).foregroundStyle(turn.speaker == .user ? .blue : .purple)
                                .frame(width: 36, alignment: .trailing)
                            Text(turn.text).textSelection(.enabled)
                        }
                        .id(turn.id)
                    }
                    if !model.assistantLive.isEmpty {
                        HStack(alignment: .top) {
                            Text("grok").font(.caption.weight(.semibold)).foregroundStyle(.purple).frame(width: 36, alignment: .trailing)
                            Text(model.assistantLive).foregroundStyle(.secondary)
                        }
                    }
                    if !model.notices.isEmpty {
                        Divider()
                        ForEach(Array(model.notices.suffix(6).enumerated()), id: \.offset) { _, n in
                            Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: model.transcript.count) { _ in
                if let last = model.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var targetView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let t = model.target {
                    Text(t.summary).font(.headline)
                    kv("source", t.source.rawValue + (model.targetIsExplicit ? " (explicit)" : ""))
                    kv("confidence", String(format: "%.2f", t.confidence))
                    kv("bounds", "\(Int(t.bounds.x)),\(Int(t.bounds.y)) \(Int(t.bounds.width))×\(Int(t.bounds.height))")
                    kv("app / window", "\(t.application) / \(t.window ?? "-")")
                    if let dom = t.accessibility.domIdentifier { kv("dom id", dom) }
                    if !t.accessibility.domClassList.isEmpty { kv("classes", t.accessibility.domClassList.joined(separator: " ")) }
                    if !t.accessibility.ancestorPath.isEmpty { kv("path", t.accessibility.ancestorPath.joined(separator: " > ")) }
                    if let s = t.sourceReference { kv("source ref", "\(s.file ?? "?"):\(s.line ?? 0) \(s.component ?? "") (\(Int(s.confidence * 100))%, \(s.method))") }
                } else {
                    Text("No target").foregroundStyle(.secondary)
                }
                if let r = model.resolution {
                    Divider()
                    Text("Candidates — \(r.reason)").font(.caption).foregroundStyle(.secondary)
                    ForEach(r.candidates) { c in
                        Text("• \(c.summary)  \(String(format: "%.2f", c.confidence))  \(c.source.rawValue)").font(.caption)
                    }
                }
                if let d = model.decision {
                    Divider()
                    kv("intent", "\(d.intent.rawValue) (\(String(format: "%.2f", d.confidence))) by \(d.decidedBy)")
                    kv("flags", [d.isExecutionCommand ? "execute" : nil, d.hasDeicticReference ? "deictic" : nil, d.needsVisualReasoning ? "visual" : nil].compactMap { $0 }.joined(separator: ", "))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsView: some View {
        List {
            ForEach(model.actions.reversed()) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(a.task.title).font(.headline)
                        Spacer()
                        Text(a.state.rawValue + (a.undone ? " · undone" : "")).font(.caption).foregroundStyle(a.state == .failed ? .red : .secondary)
                    }
                    Text("checkpoint \(a.checkpointID) · \(a.task.executionTarget.rawValue) · \(a.changedFiles.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    if let s = a.summary { Text(s).font(.caption) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var internals: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Context sent to the model") { mono(model.lastContext) }
                section("Tool calls") {
                    ForEach(model.toolLog.suffix(12).reversed()) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.name) \(e.arguments)").font(.system(.caption, design: .monospaced))
                            if let r = e.result { Text("→ \(r.prefix(400))\(e.ms.map { String(format: "  (%.0f ms)", $0) } ?? "")").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
                        }
                    }
                }
                section("Cursor task payload") { mono(model.compiledTasks.last?.prompt ?? "—") }
                section("Permissions") {
                    kv("accessibility", model.permissions.accessibility ? "granted" : "missing")
                    kv("microphone", model.permissions.microphone ? "granted" : "missing")
                    kv("screen recording", model.permissions.screenRecording ? "granted" : "missing (crops disabled)")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var latency: some View {
        let latest = Dictionary(grouping: model.latencies, by: \.stage).compactMapValues { $0.last?.milliseconds }
        return List {
            ForEach(LatencyStage.allCases, id: \.self) { stage in
                if let ms = latest[stage] {
                    HStack {
                        Text(stage.rawValue)
                        Spacer()
                        Text(String(format: "%.0f ms", ms)).monospacedDigit().foregroundStyle(ms > 800 ? .orange : .primary)
                    }
                }
            }
        }
    }

    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.logLines.suffix(200).enumerated()), id: \.offset) { _, e in
                    Text("\(e.level.label) \(e.component): \(e.message) \(e.fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(e.level >= .warn ? .orange : .secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        HStack {
            TextField("Type instead of talking (same pipeline)…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button("Send", action: send).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
    }

    private func send() {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.submitText(t)
        typed = ""
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(v).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func mono(_ s: String) -> some View {
        Text(s.isEmpty ? "—" : s)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
    }
}

extension LogLevel {
    var label: String {
        switch self {
        case .debug: return "DBG"
        case .info: return "INF"
        case .warn: return "WRN"
        case .error: return "ERR"
        }
    }
}
