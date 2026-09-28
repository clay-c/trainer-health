import Foundation

struct OutboxItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: String
    var json: Data
    var plateJPEG: Data?
    var labelJPEG: Data?
    var createdAt: Date
}

@MainActor
final class OutboxStore: ObservableObject {
    static let shared = OutboxStore()

    @Published private(set) var items: [OutboxItem] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TrainerHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("outbox.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([OutboxItem].self, from: data) {
            items = decoded
        }
    }

    func enqueue(_ item: OutboxItem) {
        items.append(item)
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
