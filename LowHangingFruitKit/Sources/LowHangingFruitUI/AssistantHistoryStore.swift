import Foundation
import SwiftUI

struct AssistantSavedChat: Codable, Identifiable {
    let id: UUID
    let updatedAt: Date
    let messages: [AssistantMessage]

    var title: String {
        let question = messages.first(where: { $0.role == .student })?.text ?? "Chat"
        return String(question.prefix(100))
    }
}

/// Local, per-school history. Demo sessions and tests default to memory only.
/// Each chat has its own atomic file so streaming never rewrites the full log.
@MainActor
final class AssistantHistoryStore: ObservableObject {
    @Published private(set) var chats: [AssistantSavedChat] = []
    @Published private(set) var errorMessage: String?
    private let directory: URL?

    init(scope: String? = nil, directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let scope {
            let safeScope = scope.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Smooth/ChatHistory/\(safeScope)", isDirectory: true)
        } else {
            self.directory = nil
        }
        guard let directory = self.directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                do { chats.append(try JSONDecoder().decode(AssistantSavedChat.self, from: Data(contentsOf: file))) }
                catch { errorMessage = "Some saved chats couldn’t be read. Their files are still on this device." }
            }
            chats.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            errorMessage = "Chat history is unavailable. Your current chat is still open."
        }
    }

    func save(_ chat: AssistantSavedChat) {
        guard !chat.messages.isEmpty else { return }
        chats.removeAll { $0.id == chat.id }
        chats.insert(chat, at: 0)
        guard let directory else { return }
        do {
            let data = try JSONEncoder().encode(chat)
            let file = directory.appendingPathComponent(chat.id.uuidString).appendingPathExtension("json")
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
        } catch {
            errorMessage = "Couldn’t save this chat. Keep it open and try again."
        }
    }
}

struct AssistantHistoryView: View {
    @ObservedObject var store: AssistantHistoryStore
    let onSelect: (AssistantSavedChat) -> Void
    let onNew: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.chats.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your conversations will appear here."))
                } else {
                    List(store.chats) { chat in
                        Button { onSelect(chat) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(chat.title).font(.lhfSans(16)).lineLimit(2)
                                Text(chat.updatedAt, style: .date)
                                    .font(.lhfSans(12)).foregroundStyle(Color.v2DateText)
                            }
                            .foregroundStyle(Color.v2Ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.v2Card)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.v2Bg.ignoresSafeArea())
            .navigationTitle("Chat history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New chat", action: onNew) }
            }
        }
    }
}
