import AppKit
import SwiftUI

struct StatusDot: View {
    let ready: Bool

    var body: some View {
        Circle()
            .fill(ready ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .accessibilityLabel(ready ? "Ready" : "Needs setup")
    }
}

/// A glass button that copies text and confirms with a checkmark.
extension Locale {
    /// The app speaks English, so its dates read in English, in the Mac's regional formats: a Mac
    /// in Germany gets "7. Oct 2026 at 22:19" and "12 minutes ago", not "vor 12 Minuten". (Changing
    /// only the language of Locale.Components drops the region, and with it the 24-hour clock.)
    static let app = Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")")
}

extension Date {
    /// "12 minutes ago".
    var relativeText: String { formatted(.relative(presentation: .named).locale(.app)) }
    /// "7 Oct 2026 at 22:19".
    var shortText: String { formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.app)) }
}

struct CopyButton: View {
    var title = "Copy"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
    }
}

/// A setup or status row: symbol, title, explanation.
struct StepRow: View {
    enum State { case done, waiting, attention, info }

    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .waiting: "circle.dashed"
        case .attention: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .done: .green
        case .waiting: .secondary
        case .attention: .orange
        case .info: .blue
        }
    }
}

/// A command or config shown in monospace with a copy button.
struct CodeRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let code: String
    /// Secrets in `code` that are masked on screen but copied in full.
    var secrets: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton { code }
            }
            Text(secrets.reduce(code) { $0.replacingOccurrences(of: $1, with: String($1.prefix(8)) + "••••••") })
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}
