import SwiftUI

struct MarkdownTextView: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .font(font)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(font)
                .textSelection(.enabled)
        }
    }
}
