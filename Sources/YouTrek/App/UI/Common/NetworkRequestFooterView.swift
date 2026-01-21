import AppKit
import SwiftUI

struct NetworkRequestFooterView: View {
    @ObservedObject var monitor: NetworkRequestMonitor

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Label("Network", systemImage: "bolt.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(monitor.entries.count) requests")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView(.vertical) {
                if monitor.entries.isEmpty {
                    Text("No requests yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.entries) { entry in
                            NetworkRequestRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxHeight: 160)
        }
        .background(.ultraThinMaterial)
    }
}

private struct NetworkRequestRow: View {
    let entry: NetworkRequestEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.method)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Text(entry.endpoint)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(statusText)
                .font(.caption2.monospaced())
                .foregroundStyle(statusColor)
                .frame(minWidth: 36, alignment: .trailing)

            Text(entry.durationText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .contextMenu {
            Button {
                copyToPasteboard(entry.urlString)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
        }
        .help(entry.errorDescription ?? "")
    }

    private var statusText: String {
        if entry.isPending {
            return "pending"
        }
        if let statusCode = entry.statusCode {
            return String(statusCode)
        }
        return entry.errorDescription == nil ? "-" : "ERR"
    }

    private var statusColor: Color {
        if entry.isPending {
            return .secondary
        }
        if let statusCode = entry.statusCode {
            if statusCode >= 400 {
                return .red
            }
            if statusCode >= 300 {
                return .orange
            }
            return .secondary
        }
        return entry.errorDescription == nil ? .secondary : .red
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
