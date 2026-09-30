import SwiftUI

@main
struct TrainerHealthApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    guard SetupLink.apply(url) else { return }
                    model.reloadSettings()
                    Task { await model.refresh() }
                }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var reachable = false
    @Published var status = ""
    @Published var planText = SyncService.cachedPlan()
    @Published var planExercises = SyncService.cachedExercises()
    @Published var note = ""
    @Published var noteReply = ""
    @Published var noteBusy = false
    @Published var planNoteReply = ""
    @Published var planNoteBusy = false
    @Published var weightText = ""
    @Published var todayWeight: Double?
    @Published var editingWeight = false
    @Published var weightBusy = false
    @Published var weightMessage = ""
    @Published var syncBusy = false
    @Published var syncMessage = ""
    @Published var exports: [HealthExport] = []
    @Published var baseURL = AppSettings.baseURLString
    @Published var token = AppSettings.token
    @Published var botUsername = AppSettings.botUsername

    var pendingCount: Int { OutboxStore.shared.items.count }
    var showPendingBanner: Bool { !reachable && pendingCount > 0 }

    func refresh() async {
        saveSettings()
        reachable = await SyncService.reachable()
        if reachable {
            if let plan = try? await SyncService.currentPlan() {
                planText = plan.text
                planExercises = plan.exercises
            }
            if let pounds = try? await SyncService.todayWeight() {
                todayWeight = pounds
                if pounds != nil {
                    editingWeight = false
                }
            }
            if let history = try? await SyncService.exportHistory() {
                exports = history
            }
            if pendingCount > 0 {
                _ = try? await SyncService.flush()
            }
        }
        objectWillChange.send()
    }

    func reloadSettings() {
        baseURL = AppSettings.baseURLString
        token = AppSettings.token
        botUsername = AppSettings.botUsername
        status = "Setup saved from the code."
    }

    func saveSettings() {
        AppSettings.baseURLString = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.botUsername = botUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func logWeight() async {
        guard let pounds = Double(weightText) else {
            weightMessage = "Enter a weight in pounds."
            return
        }
        weightBusy = true
        defer { weightBusy = false }
        do {
            try await SyncService.saveWeight(pounds: pounds)
            weightText = ""
            await refresh()
            weightMessage = reachable ? "Weight saved." : "Weight is waiting on this phone."
        } catch {
            weightMessage = error.localizedDescription
        }
    }

    func syncHealth() async {
        syncBusy = true
        defer { syncBusy = false }
        do {
            let result = try await SyncService.syncHealth()
            await refresh()
            syncMessage = result.summary
        } catch {
            syncMessage = error.localizedDescription
            reachable = false
        }
    }

    func sendNote() async {
        await deliverNote(text: note, purpose: "", reply: \.noteReply, busy: \.noteBusy) {
            self.note = ""
        }
    }

    func sendPlanNote(_ text: String, clear: @escaping () -> Void, onReply: @escaping () -> Void) async {
        await deliverNote(text: text, purpose: "plan", reply: \.planNoteReply, busy: \.planNoteBusy, clear: clear, onReply: onReply)
    }

    private func deliverNote(
        text: String,
        purpose: String,
        reply replyKey: ReferenceWritableKeyPath<AppModel, String>,
        busy busyKey: ReferenceWritableKeyPath<AppModel, Bool>,
        clear: (() -> Void)? = nil,
        onReply: (() -> Void)? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard reachable, let client = try? SyncService.client() else {
            status = "The ledger is not reachable. Open Telegram instead."
            return
        }
        self[keyPath: busyKey] = true
        self[keyPath: replyKey] = ""
        defer { self[keyPath: busyKey] = false }
        do {
            let id = try await client.sendNote(clientId: UUID().uuidString, text: trimmed, purpose: purpose)
            clear?()
            status = "Sent. The trainer often takes a minute or more."
            for _ in 0..<36 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if let reply = try await client.noteReply(id: id), !reply.isEmpty {
                    self[keyPath: replyKey] = reply
                    if let plan = try? await SyncService.currentPlan() {
                        planText = plan.text
                        planExercises = plan.exercises
                    }
                    status = "Reply received."
                    onReply?()
                    return
                }
            }
            status = "Still waiting. The reply will also be in Telegram."
        } catch {
            status = error.localizedDescription
        }
    }
}
