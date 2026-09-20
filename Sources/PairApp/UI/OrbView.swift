import PairCore
import SwiftUI

/// The floating orb. One glyph, one colour, a subtle pulse; nothing else.
struct OrbView: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        let style = Self.style(for: model.state)
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(style.color.opacity(0.25))
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulse && style.pulses ? 1.35 : 1.0)
                    .opacity(pulse && style.pulses ? 0.0 : 1.0)
                    .animation(style.pulses ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : .default, value: pulse)
                Circle()
                    .fill(LinearGradient(colors: [style.color.opacity(0.95), style.color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .shadow(color: style.color.opacity(0.6), radius: 8)
                Image(systemName: style.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(style.color.opacity(0.35), lineWidth: 1))
        .onAppear { pulse = true }
        .animation(.easeInOut(duration: 0.2), value: model.state)
    }

    private var caption: String {
        switch model.state {
        case .idle: return ""
        case .muted: return "muted"
        case .listening:
            if let t = model.target, model.targetIsExplicit { return "→ \(t.label.isEmpty ? t.role : t.label)" }
            return model.partialUserText.isEmpty ? "listening…" : model.partialUserText
        case .targeting:
            return "→ " + (model.target.map { $0.label.isEmpty ? $0.role : $0.label } ?? "target")
        case .thinking: return model.partialUserText.isEmpty ? "thinking…" : model.partialUserText
        case .speaking: return model.assistantLive.isEmpty ? "" : String(model.assistantLive.suffix(90))
        case .executing:
            let running = model.actions.last { $0.state == .running || $0.state == .queued }
            return running.map { "Cursor: \($0.task.title)" } ?? "Cursor is working…"
        case .success: return model.actions.last.map { $0.undone ? "reverted" : "done — \($0.changedFiles.count) file\($0.changedFiles.count == 1 ? "" : "s")" } ?? "done"
        case .error: return model.lastError.map { String($0.prefix(80)) } ?? "error"
        }
    }

    struct Style { var color: Color; var symbol: String; var pulses: Bool }

    static func style(for s: AssistantState) -> Style {
        switch s {
        case .idle: return Style(color: .gray, symbol: "waveform", pulses: false)
        case .muted: return Style(color: .gray, symbol: "mic.slash.fill", pulses: false)
        case .listening: return Style(color: .blue, symbol: "mic.fill", pulses: true)
        case .targeting: return Style(color: .cyan, symbol: "scope", pulses: true)
        case .thinking: return Style(color: .purple, symbol: "ellipsis", pulses: true)
        case .speaking: return Style(color: .indigo, symbol: "speaker.wave.2.fill", pulses: true)
        case .executing: return Style(color: .orange, symbol: "hammer.fill", pulses: true)
        case .success: return Style(color: .green, symbol: "checkmark", pulses: false)
        case .error: return Style(color: .red, symbol: "exclamationmark", pulses: false)
        }
    }
}
