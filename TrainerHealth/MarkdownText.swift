import SwiftUI

struct MarkdownText: View {
    var text: String

    var body: some View {
        Text(rendered)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
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
