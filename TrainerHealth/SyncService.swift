import Foundation

enum SyncService {
    static func client() throws -> LedgerClient {
        guard let url = AppSettings.normalizedBaseURL(), !AppSettings.token.isEmpty else {
            throw LedgerError.notConfigured
        }
        return LedgerClient(baseURL: url, token: AppSettings.token)
    }

    @MainActor
    static func reachable() async -> Bool {
        guard let client = try? client() else { return false }
        return await client.health()
    }

    @MainActor
    static func saveWeight(pounds: Double) async throws {
        let body: [String: Any] = [
            "kind": "body_mass",
            "occurred_at": ISO8601Flex.string(from: Date()),
            "client_id": UUID().uuidString,
            "weight_lb": pounds,
        ]
        try await enqueueOrSend(kind: "body_mass", json: body, plate: nil, label: nil)
    }

    @MainActor
    static func saveWorkout(
        exercises: [[String: Any]],
        durationMin: Double,
        location: String,
        prescribedText: String = "",
        skipped: [String] = []
    ) async throws {
        let body: [String: Any] = [
            "kind": "workout",
            "occurred_at": ISO8601Flex.string(from: Date()),
            "client_id": UUID().uuidString,
            "payload": [
                "duration_min": durationMin,
                "location": location,
                "prescribed": prescribedText,
                "exercises": exercises,
                "skipped": skipped,
            ],
        ]
        try await enqueueOrSend(kind: "workout", json: body, plate: nil, label: nil)
    }

    @MainActor
    static func saveMeal(text: String, plate: Data?, label: Data?) async throws {
        let id = UUID()
        let body: [String: Any] = [
            "kind": "meal",
            "text": text,
            "occurred_at": ISO8601Flex.string(from: Date()),
            "client_id": id.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        if await reachable(), let client = try? client() {
            try await client.postMeal(clientId: id.uuidString, text: text, occurredAt: Date(), plate: plate, label: label)
            return
        }
        OutboxStore.shared.enqueue(OutboxItem(id: id, kind: "meal", json: data, plateJPEG: plate, labelJPEG: label, createdAt: Date()))
    }

    @MainActor
    static func saveMealText(_ text: String) async throws {
        try await saveMeal(text: text, plate: nil, label: nil)
    }

    @MainActor
    static func flush() async throws -> Int {
        guard let client = try? client(), await client.health() else { throw LedgerError.unreachable }
        var sent = 0
        for item in OutboxStore.shared.items {
            let object = try JSONSerialization.jsonObject(with: item.json) as? [String: Any] ?? [:]
            if item.kind == "meal" {
                try await client.postMeal(
                    clientId: item.id.uuidString,
                    text: object["text"] as? String ?? "",
                    occurredAt: ISO8601Flex.date(from: object["occurred_at"] as? String ?? "") ?? item.createdAt,
                    plate: item.plateJPEG,
                    label: item.labelJPEG
                )
            } else {
                var body = object
                body["client_id"] = item.id.uuidString
                try await client.postFact(body)
            }
            OutboxStore.shared.remove(id: item.id)
            sent += 1
        }
        return sent
    }

    @MainActor
    static func syncHealth() async throws -> Int {
        guard let client = try? client(), await client.health() else { throw LedgerError.unreachable }
        _ = try await flush()
        try await HealthWriter.requestAccess()
        let events = try await client.pendingEvents()
        var receipts: [[String: String]] = []
        for event in events {
            guard let uuid = try await HealthWriter.write(event) else { continue }
            let ids = event.alsoIds ?? [event.id]
            for id in ids {
                receipts.append([
                    "event_id": id.uuidString,
                    "channel": event.channel,
                    "healthkit_uuid": uuid.uuidString,
                ])
            }
        }
        if !receipts.isEmpty {
            try await client.postReceipts(receipts)
        }
        return events.count
    }

    @MainActor
    static func planText() async throws -> String {
        try await currentPlan().text
    }

    @MainActor
    static func currentPlan() async throws -> TrainingPlan {
        guard let client = try? client(), await client.health() else { throw LedgerError.unreachable }
        let plan = try await client.currentPlan()
        UserDefaults.standard.set(plan.text, forKey: "cachedPlanText")
        if let data = try? JSONEncoder().encode(plan.exercises) {
            UserDefaults.standard.set(data, forKey: "cachedPlanExercises")
        }
        return plan
    }

    static func cachedPlan() -> String {
        UserDefaults.standard.string(forKey: "cachedPlanText") ?? ""
    }

    static func cachedExercises() -> [PrescribedExercise] {
        guard let data = UserDefaults.standard.data(forKey: "cachedPlanExercises"),
              let rows = try? JSONDecoder().decode([PrescribedExercise].self, from: data) else { return [] }
        return rows
    }

    @MainActor
    private static func enqueueOrSend(kind: String, json: [String: Any], plate: Data?, label: Data?) async throws {
        let id = UUID(uuidString: json["client_id"] as? String ?? "") ?? UUID()
        if await reachable(), let client = try? client() {
            try await client.postFact(json)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        OutboxStore.shared.enqueue(OutboxItem(id: id, kind: kind, json: data, plateJPEG: plate, labelJPEG: label, createdAt: Date()))
    }
}
