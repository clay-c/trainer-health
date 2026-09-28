import SwiftUI

@main
struct TrainerHealthApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var reachable = false
    @Published var status = ""
    @Published var planText = SyncService.cachedPlan()
    @Published var note = ""
    @Published var noteReply = ""
    @Published var noteBusy = false
    @Published var weightText = ""
    @Published var baseURL = AppSettings.baseURLString
    @Published var token = AppSettings.token
    @Published var botUsername = AppSettings.botUsername

    var pendingCount: Int { OutboxStore.shared.items.count }
    var showPendingBanner: Bool { !reachable && pendingCount > 0 }

    func refresh() async {
        saveSettings()
        reachable = await SyncService.reachable()
        if reachable {
            planText = (try? await SyncService.planText()) ?? planText
            if pendingCount > 0 {
                _ = try? await SyncService.flush()
            }
        }
        objectWillChange.send()
    }

    func saveSettings() {
        AppSettings.baseURLString = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.botUsername = botUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func logWeight() async {
        guard let pounds = Double(weightText) else {
            status = "Enter a weight in pounds."
            return
        }
        do {
            try await SyncService.saveWeight(pounds: pounds)
            weightText = ""
            await refresh()
            status = reachable ? "Weight saved." : "Weight is waiting on this phone."
        } catch {
            status = error.localizedDescription
        }
    }

    func syncHealth() async {
        do {
            let count = try await SyncService.syncHealth()
            await refresh()
            status = "Health sync looked at \(count) stored rows."
        } catch {
            status = error.localizedDescription
            reachable = false
        }
    }

    func sendNote() async {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard reachable, let client = try? SyncService.client() else {
            status = "The ledger is not reachable. Open Telegram instead."
            return
        }
        noteBusy = true
        noteReply = ""
        defer { noteBusy = false }
        do {
            let id = try await client.sendNote(clientId: UUID().uuidString, text: text)
            status = "Sent. The trainer often takes a minute or more."
            for _ in 0..<36 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if let reply = try await client.noteReply(id: id), !reply.isEmpty {
                    noteReply = reply
                    status = "Reply received."
                    return
                }
            }
            status = "Still waiting. The reply will also be in Telegram."
        } catch {
            status = error.localizedDescription
        }
    }
}
