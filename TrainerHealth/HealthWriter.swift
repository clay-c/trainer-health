import Foundation
import HealthKit

struct HealthWrite {
    var uuid: UUID
    var created: Bool
}

enum HealthWriter {
    static let store = HKHealthStore()

    static func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    static func write(_ event: LedgerEvent) async throws -> HealthWrite? {
        if let existing = try await existingMatch(event) {
            return HealthWrite(uuid: existing, created: false)
        }
        switch event.kind {
        case "body_mass":
            guard let pounds = event.bodyMassLb,
                  let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return nil }
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .pound(), doubleValue: pounds),
                start: event.occurredAt,
                end: event.occurredAt
            )
            try await store.save(sample)
            return HealthWrite(uuid: sample.uuid, created: true)
        case "dietary_protein":
            guard let grams = event.proteinG,
                  let type = HKObjectType.quantityType(forIdentifier: .dietaryProtein) else { return nil }
            var metadata: [String: Any] = [:]
            if let meal = event.meal { metadata[HKMetadataKeyFoodType] = meal }
            if let tier = event.proteinTier { metadata["protein_tier"] = tier }
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .gram(), doubleValue: grams),
                start: event.occurredAt,
                end: event.occurredAt,
                metadata: metadata
            )
            try await store.save(sample)
            return HealthWrite(uuid: sample.uuid, created: true)
        case "sleep":
            guard let hours = event.sleepH,
                  let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
            let end = event.occurredAt
            let start = end.addingTimeInterval(-hours * 3600)
            let sample = HKCategorySample(
                type: type,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: start,
                end: end
            )
            try await store.save(sample)
            return HealthWrite(uuid: sample.uuid, created: true)
        case "waist":
            guard let cm = event.waistCm,
                  let type = HKObjectType.quantityType(forIdentifier: .waistCircumference) else { return nil }
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: cm),
                start: event.occurredAt,
                end: event.occurredAt
            )
            try await store.save(sample)
            return HealthWrite(uuid: sample.uuid, created: true)
        case "symptom":
            guard let name = event.symptom, let identifier = symptomIdentifier(name),
                  let type = HKObjectType.categoryType(forIdentifier: identifier) else { return nil }
            let sample = HKCategorySample(
                type: type,
                value: severity(event.severity).rawValue,
                start: event.occurredAt,
                end: event.occurredAt
            )
            try await store.save(sample)
            return HealthWrite(uuid: sample.uuid, created: true)
        case "workout":
            return try await writeWorkout(event)
        default:
            return nil
        }
    }

    private static func writeWorkout(_ event: LedgerEvent) async throws -> HealthWrite? {
        let workout = event.workout
        let minutes = workout?.durationMin ?? 30
        let end = event.occurredAt
        let start = end.addingTimeInterval(-minutes * 60)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        let summary = (workout?.exercises ?? []).map { exercise in
            let sets = exercise.sets?.count ?? 0
            let load = exercise.loadLb.map { " \($0) lb" } ?? ""
            return "\(exercise.name)\(load) x\(sets)"
        }.joined(separator: "; ")
        var metadata: [String: Any] = ["ledger_fact_id": event.id.uuidString]
        if workout?.durationEstimated == true {
            metadata["duration_estimated"] = true
        }
        if !summary.isEmpty {
            metadata["trainer_exercises"] = String(summary.prefix(500))
        }
        try await builder.beginCollection(at: start)
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: end)
        let finished = try await builder.finishWorkout()
        guard let uuid = finished?.uuid else { return nil }
        return HealthWrite(uuid: uuid, created: true)
    }

    private static func severity(_ name: String?) -> HKCategoryValueSeverity {
        switch name {
        case "mild": return .mild
        case "moderate": return .moderate
        case "severe": return .severe
        case "none", "not_present": return .notPresent
        default: return .unspecified
        }
    }

    private static func symptomIdentifier(_ name: String) -> HKCategoryTypeIdentifier? {
        switch name {
        case "nausea": return .nausea
        case "fatigue": return .fatigue
        case "vomiting": return .vomiting
        case "appetite": return .appetiteChanges
        case "dizziness": return .dizziness
        case "headache": return .headache
        case "constipation": return .constipation
        case "diarrhea": return .diarrhea
        case "heartburn": return .heartburn
        case "bloating": return .bloating
        default: return nil
        }
    }

    static func removeDuplicates() async throws -> Int {
        var extras: [HKObject] = []
        extras += copiesToDelete(among: try await allSamples(quantity: .bodyMass)) { sample in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return "\(dayKey(quantity.startDate))|\(bucket(quantity.quantity.doubleValue(for: .pound())))"
        }
        extras += copiesToDelete(among: try await allSamples(quantity: .dietaryProtein)) { sample in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            let meal = quantity.metadata?[HKMetadataKeyFoodType] as? String ?? ""
            return "\(dayKey(quantity.startDate))|\(bucket(quantity.quantity.doubleValue(for: .gram())))|\(meal)"
        }
        extras += copiesToDelete(among: try await allSamples(quantity: .waistCircumference)) { sample in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return "\(dayKey(quantity.startDate))|\(bucket(quantity.quantity.doubleValue(for: .meterUnit(with: .centi))))"
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            extras += copiesToDelete(among: try await allSamples(type: sleep)) { sample in
                guard let category = sample as? HKCategorySample else { return nil }
                let hours = category.endDate.timeIntervalSince(category.startDate) / 3600
                return "\(dayKey(category.endDate))|\(bucket(hours))"
            }
        }
        for name in symptomNames {
            guard let identifier = symptomIdentifier(name),
                  let type = HKObjectType.categoryType(forIdentifier: identifier) else { continue }
            extras += copiesToDelete(among: try await allSamples(type: type)) { sample in
                guard let category = sample as? HKCategorySample else { return nil }
                return "\(dayKey(category.startDate))|\(category.value)"
            }
        }
        extras += copiesToDelete(among: try await allSamples(type: HKObjectType.workoutType())) { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            if let fact = workout.metadata?["ledger_fact_id"] as? String, !fact.isEmpty {
                return "fact|\(fact)"
            }
            let minutes = Int((workout.duration / 60).rounded())
            return "\(dayKey(workout.endDate))|\(workout.workoutActivityType.rawValue)|\(minutes)"
        }
        if extras.isEmpty { return 0 }
        try await store.delete(extras)
        return extras.count
    }

    private static func existingMatch(_ event: LedgerEvent) async throws -> UUID? {
        switch event.kind {
        case "body_mass":
            guard let pounds = event.bodyMassLb else { return nil }
            return try await quantityMatch(.bodyMass, unit: .pound(), value: pounds, on: event.occurredAt)
        case "dietary_protein":
            guard let grams = event.proteinG else { return nil }
            return try await quantityMatch(.dietaryProtein, unit: .gram(), value: grams, on: event.occurredAt, meal: event.meal ?? "")
        case "waist":
            guard let cm = event.waistCm else { return nil }
            return try await quantityMatch(.waistCircumference, unit: .meterUnit(with: .centi), value: cm, on: event.occurredAt)
        case "sleep":
            guard let hours = event.sleepH,
                  let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
            let rows = try await samples(type: type, around: event.occurredAt)
            return rows.compactMap { $0 as? HKCategorySample }.first { category in
                let recorded = category.endDate.timeIntervalSince(category.startDate) / 3600
                return dayKey(category.endDate) == dayKey(event.occurredAt) && bucket(recorded) == bucket(hours)
            }?.uuid
        case "symptom":
            guard let name = event.symptom, let identifier = symptomIdentifier(name),
                  let type = HKObjectType.categoryType(forIdentifier: identifier) else { return nil }
            let wanted = severity(event.severity).rawValue
            let rows = try await samples(type: type, around: event.occurredAt)
            return rows.compactMap { $0 as? HKCategorySample }.first { category in
                dayKey(category.startDate) == dayKey(event.occurredAt) && category.value == wanted
            }?.uuid
        case "workout":
            let fact = event.id.uuidString
            let rows = try await samples(type: HKObjectType.workoutType(), around: event.occurredAt)
            return rows.compactMap { $0 as? HKWorkout }.first { workout in
                workout.metadata?["ledger_fact_id"] as? String == fact
            }?.uuid
        default:
            return nil
        }
    }

    private static func quantityMatch(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        value: Double,
        on day: Date,
        meal: String? = nil
    ) async throws -> UUID? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let rows = try await samples(type: type, around: day)
        return rows.compactMap { $0 as? HKQuantitySample }.first { quantity in
            guard dayKey(quantity.startDate) == dayKey(day),
                  bucket(quantity.quantity.doubleValue(for: unit)) == bucket(value) else { return false }
            if let meal {
                let recorded = quantity.metadata?[HKMetadataKeyFoodType] as? String ?? ""
                return recorded == meal
            }
            return true
        }?.uuid
    }

    private static func copiesToDelete(among samples: [HKSample], key: (HKSample) -> String?) -> [HKObject] {
        var groups: [String: [HKSample]] = [:]
        for sample in samples {
            guard let group = key(sample) else { continue }
            groups[group, default: []].append(sample)
        }
        let mine = HKSource.default()
        var doomed: [HKObject] = []
        for samples in groups.values where samples.count > 1 {
            let sorted = samples.sorted { $0.startDate < $1.startDate }
            let keep = sorted.first { $0.sourceRevision.source != mine } ?? sorted[0]
            for sample in sorted where sample.uuid != keep.uuid && sample.sourceRevision.source == mine {
                doomed.append(sample)
            }
        }
        return doomed
    }

    private static func allSamples(quantity identifier: HKQuantityTypeIdentifier) async throws -> [HKSample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        return try await allSamples(type: type)
    }

    private static func allSamples(type: HKSampleType) async throws -> [HKSample] {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date().addingTimeInterval(86_400)
        return try await samples(type: type, from: start, to: end)
    }

    private static func samples(type: HKSampleType, around day: Date) async throws -> [HKSample] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: day)) ?? day
        let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: day)) ?? day
        return try await samples(type: type, from: start, to: end)
    }

    private static func samples(type: HKSampleType, from start: Date, to end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, found, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: found ?? [])
            }
            store.execute(query)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func bucket(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static let symptomNames = ["nausea", "fatigue", "vomiting", "appetite", "dizziness", "headache", "constipation", "diarrhea", "heartburn", "bloating"]

    private static var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for identifier in [HKQuantityTypeIdentifier.bodyMass, .waistCircumference, .dietaryProtein] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        for name in symptomNames {
            if let identifier = symptomIdentifier(name),
               let type = HKObjectType.categoryType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(shareTypes)
        for identifier in [
            HKQuantityTypeIdentifier.stepCount,
            .heartRate,
            .restingHeartRate,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        return types
    }
}
