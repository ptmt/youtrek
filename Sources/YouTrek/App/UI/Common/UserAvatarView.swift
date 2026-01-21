import SwiftUI

struct UserAvatarView: View {
    let person: Person?
    let size: CGFloat

    init(person: Person?, size: CGFloat = 20) {
        self.person = person
        self.size = size
    }

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Circle())
            .overlay(Circle().stroke(.separator.opacity(0.4), lineWidth: 1))
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let url = person?.avatarURL {
            AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
            if let initials {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var initials: String? {
        guard let person else { return nil }
        let parts = person.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == " " || $0 == "\n" || $0 == "\t" }
        guard let first = parts.first?.first else { return nil }
        var letters: [Character] = [first]
        if parts.count > 1, let second = parts[1].first {
            letters.append(second)
        }
        return String(letters).uppercased()
    }

    private var accessibilityLabel: Text {
        if let person {
            return Text("Assignee: \(person.displayName)")
        }
        return Text("Unassigned")
    }
}
