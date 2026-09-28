import SwiftUI

struct MarkdownText: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MarkdownLines.blocks(from: text)) { block in
                if block.kind == .blank {
                    Spacer().frame(height: 6)
                } else {
                    Text(block.inline)
                        .font(block.font)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct CollapsibleMarkdown: View {
    var title: String
    var text: String
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(title, isExpanded: $expanded) {
            if text.isEmpty {
                Text("Nothing stored yet.")
                    .foregroundStyle(.secondary)
            } else {
                MarkdownText(text: text)
            }
        }
    }
}

private struct MarkdownBlock: Identifiable {
    var id: Int
    var kind: Kind
    var inline: AttributedString

    enum Kind {
        case heading, body, blank
    }

    var font: Font {
        kind == .heading ? .headline : .body
    }
}

private enum MarkdownLines {
    static func blocks(from source: String) -> [MarkdownBlock] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return MarkdownBlock(id: index, kind: .blank, inline: AttributedString())
            }
            var kind = MarkdownBlock.Kind.body
            var content = trimmed
            if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                kind = .heading
                content = String(trimmed[range.upperBound...])
            }
            let inline = (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
            return MarkdownBlock(id: index, kind: kind, inline: inline)
        }
    }
}
