import AppKit
import SwiftUI
import WorkScribeCore

/// One turn: the question on blush (what you typed), the answer with a serif lead and moment rows below.
struct MessageView: View {
    let message: AskMessage
    let open: (WorkScribeLink) -> Void
    var compact = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text).font(.system(size: compact ? 13 : 15)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.blush.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            AnswerView(message: message, open: open, compact: compact)
        }
    }
}

struct AnswerView: View {
    let message: AskMessage
    let open: (WorkScribeLink) -> Void
    var compact = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trace = message.trace {
                DisclosureGroup {
                    ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, step in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title + (step.status == "error" ? " · Couldn’t complete" : ""))
                            if let detail = step.detail { Text(detail).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                } label: {
                    Text([trace.model ?? "How this was made", trace.location,
                          trace.durationMs.map { String(format: "%.1f s", Double($0) / 1000) }].compactMap { $0 }.joined(separator: " · "))
                }.font(.caption).foregroundStyle(.secondary)
            }
            if message.state == .working && message.text.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking through your meetings and files…") }
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            if !message.text.isEmpty {
                answerText.font(compact ? Theme.serif(14, weight: .regular) : Theme.serif(17, weight: .regular))
                    .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "cite", let number = Int(url.host ?? ""),
                           let citation = message.citations.first(where: { $0.number == number }) { open(citation.moment.link) }
                        return .handled
                    })
            }
            if let detail = message.detail, message.state != .answered {
                Text(detail).font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            if !message.citations.isEmpty {
                VStack(spacing: 6) {
                    ForEach(message.citations) { citation in MomentRow(citation: citation, open: open, compact: compact) }
                }
            }
            if message.state == .answered, !compact {
                HStack(spacing: 12) {
                    Button(copied ? "Copied" : "Copy with sources") { copy() }.buttonStyle(.borderless)
                    if let detail = message.detail { Text(detail).foregroundStyle(Theme.inkMuted) }
                }.font(Theme.caption)
            }
        }
    }

    /// Citation markers become tappable superscript numbers in indigo.
    private var answerText: Text {
        CitationMapper.pieces(message.text).reduce(Text("")) { result, piece in
            switch piece {
            case .text(let run): return result + Text(run)
            case .citation(let number):
                var marker = AttributedString(" \(number)")
                marker.link = URL(string: "cite://\(number)")
                marker.foregroundColor = Theme.indigo
                marker.font = .system(size: compact ? 10 : 11, weight: .bold)
                marker.baselineOffset = 5
                return result + Text(marker)
            }
        }
    }

    private func copy() {
        let sources = message.citations.map { "[\($0.number)] \($0.moment.sourceName) · \($0.moment.locator) — \($0.moment.link.url.absoluteString)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([message.text, ""] + sources).joined(separator: "\n"), forType: .string)
        copied = true
    }
}

/// A cited moment: number, who and where, the excerpt. Opens the meeting at the time or the file at the page.
struct MomentRow: View {
    let citation: AskCitation
    let open: (WorkScribeLink) -> Void
    var compact = false
    @State private var hovering = false

    var body: some View {
        let moment = citation.moment
        Button { open(moment.link) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(citation.number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onIndigo)
                    .frame(width: 18, height: 18).background(Theme.indigo, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: icon(moment)).font(.system(size: 11)).foregroundStyle(Theme.indigo)
                        Text(moment.sourceName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if !moment.locator.isEmpty { Text("· " + moment.locator).font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1) }
                        if moment.attached {
                            Text(moment.ref.contains("/attachments/") ? "attached" : "this meeting").font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.sky, in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    if !compact || hovering, let excerpt = excerpt(moment) {
                        Text(excerpt).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(compact ? 2 : 3)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(10)
            .background(Theme.indigoWash.opacity(hovering ? 0.30 : 0.18), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(moment.isMeeting ? "Open the meeting at this moment" : "Open the file here")
    }

    private func icon(_ moment: AskMoment) -> String {
        switch ChunkKind(rawValue: moment.kind) {
        case .meetingSegment: return "person.wave.2"
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        default: return "doc.text"
        }
    }

    private func excerpt(_ moment: AskMoment) -> AttributedString? {
        let raw = moment.snippet ?? (moment.text.isEmpty ? nil : String(moment.text.prefix(240)))
        guard let raw else { return nil }
        // «matched» words from keyword search are shown in bold.
        var out = AttributedString()
        var bold = false
        for part in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "«" || $0 == "»" }) {
            var run = AttributedString(String(part))
            if bold { run.font = .system(size: 13, weight: .semibold) }
            out += run
            bold.toggle()
        }
        return out
    }
}
