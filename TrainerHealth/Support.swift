import Foundation
import Security

enum ISO8601Flex {
    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum KeychainStore {
    private static let service = "me.ycross.trainer-health"

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

enum AppSettings {
    static let urlKey = "ledgerBaseURL"
    static let botKey = "telegramBotUsername"

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var botUsername: String {
        get { UserDefaults.standard.string(forKey: botKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: botKey) }
    }

    static var token: String {
        get { KeychainStore.get(account: "ledgerToken") }
        set { KeychainStore.set(newValue, account: "ledgerToken") }
    }

    static func normalizedBaseURL() -> URL? {
        var text = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func telegramURL() -> URL? {
        let name = botUsername.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !name.isEmpty else { return nil }
        return URL(string: "https://t.me/\(name)")
    }
}

struct LedgerEvent: Decodable, Identifiable {
    var id: UUID
    var channel: String
    var kind: String
    var occurredAt: Date
    var alsoIds: [UUID]?
    var bodyMassLb: Double?
    var proteinG: Double?
    var meal: String?
    var proteinTier: String?
    var sleepH: Double?
    var waistCm: Double?
    var symptom: String?
    var severity: String?
    var workout: WorkoutBody?

    struct WorkoutBody: Decodable {
        var durationMin: Double?
        var durationEstimated: Bool?
        var location: String?
        var exercises: [Exercise]
    }

    struct Exercise: Decodable {
        var name: String
        var loadLb: Double?
        var sets: [SetRow]?
    }

    struct SetRow: Decodable {
        var reps: Int?
        var rir: Double?
    }
}

struct PendingEvents: Decodable {
    var events: [LedgerEvent]
}

struct HealthExport: Decodable, Identifiable {
    var id: UUID
    var exportedAt: Date
    var occurredAt: Date
    var channel: String
    var label: String
}

struct ExportList: Decodable {
    var exports: [HealthExport]
}

struct PrescribedExercise: Codable, Equatable, Identifiable {
    var name: String
    var prescribed: String
    var id: String { name }
}

struct TrainingPlan: Equatable {
    var text: String
    var exercises: [PrescribedExercise]
}

enum LedgerError: LocalizedError {
    case unreachable
    case badStatus(Int)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .unreachable: "The ledger is not reachable."
        case .badStatus(let code): "The ledger responded with HTTP \(code)."
        case .notConfigured: "Set the ledger address and token in Settings."
        }
    }
}

struct LedgerClient: Sendable {
    var baseURL: URL
    var token: String

    func health() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "healthz"))
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func postFact(_ body: [String: Any]) async throws {
        try await send(path: "v1/facts", method: "POST", json: body)
    }

    func postMeal(clientId: String, text: String, occurredAt: Date, plate: Data?, label: Data?) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/meals"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        func field(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("client_id", clientId)
        field("text", text)
        field("occurred_at", ISO8601Flex.string(from: occurredAt))
        func file(_ name: String, _ bytes: Data) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(bytes)
            data.append("\r\n".data(using: .utf8)!)
        }
        if let plate { file("plate", plate) }
        if let label { file("label", label) }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LedgerError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw LedgerError.badStatus(http.statusCode) }
    }

    func currentPlan() async throws -> TrainingPlan {
        let data = try await send(path: "v1/plan/current", method: "GET", json: nil)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = object?["text"] as? String ?? ""
        let rows = object?["exercises"] as? [[String: Any]] ?? []
        let exercises = rows.compactMap { row -> PrescribedExercise? in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return PrescribedExercise(name: name, prescribed: row["prescribed"] as? String ?? "")
        }
        return TrainingPlan(text: text, exercises: exercises)
    }

    func sendNote(clientId: String, text: String, purpose: String = "") async throws -> String {
        var body: [String: String] = ["client_id": clientId, "text": text]
        if !purpose.isEmpty { body["purpose"] = purpose }
        let data = try await send(path: "v1/notes", method: "POST", json: body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? String ?? ""
    }

    func noteReply(id: String) async throws -> String? {
        let data = try await send(path: "v1/notes/\(id)", method: "GET", json: nil)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["reply"] as? String
    }

    func pendingEvents() async throws -> [LedgerEvent] {
        let data = try await send(path: "v1/exports/pending", method: "GET", json: nil)
        return try Self.decoder().decode(PendingEvents.self, from: data).events
    }

    func exports() async throws -> [HealthExport] {
        let data = try await send(path: "v1/exports", method: "GET", json: nil)
        return try Self.decoder().decode(ExportList.self, from: data).exports
    }

    func weighIn(from start: Date, to end: Date) async throws -> Double? {
        var parts = URLComponents(url: baseURL.appending(path: "v1/weigh-in"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "start", value: ISO8601Flex.string(from: start)),
            URLQueryItem(name: "end", value: ISO8601Flex.string(from: end)),
        ]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LedgerError.unreachable }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let number = object?["weight_lb"] as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Flex.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date")
            }
            return date
        }
        return decoder
    }

    func postReceipts(_ receipts: [[String: String]]) async throws {
        _ = try await send(path: "v1/exports", method: "POST", json: ["receipts": receipts])
    }

    func doses(from start: Date, to end: Date) async throws -> String {
        var parts = URLComponents(url: baseURL.appending(path: "v1/doses"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "start", value: ISO8601Flex.string(from: start)),
            URLQueryItem(name: "end", value: ISO8601Flex.string(from: end)),
        ]
        guard let url = parts?.url else { return "" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = object?["doses"] as? [[String: Any]] ?? []
        return rows.map { row in
            let when = row["occurred_at"] as? String ?? ""
            let payload = row["payload"] as? [String: Any] ?? [:]
            let dose = payload["dose_mg"] ?? payload["dose"] ?? ""
            return "- \(when) \(dose)"
        }.joined(separator: "\n")
    }

    @discardableResult
    private func send(path: String, method: String, json: Any?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LedgerError.unreachable }
            guard (200..<300).contains(http.statusCode) else { throw LedgerError.badStatus(http.statusCode) }
            return data
        } catch let error as LedgerError {
            throw error
        } catch {
            throw LedgerError.unreachable
        }
    }
}
