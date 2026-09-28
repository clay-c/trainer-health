import Foundation
import HealthKit

enum HealthWriter {
    static let store = HKHealthStore()

    static func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    static func write(_ event: LedgerEvent) async throws -> UUID? {
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
            return sample.uuid
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
            return sample.uuid
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
            return sample.uuid
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
            return sample.uuid
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
            return sample.uuid
        case "workout":
            return try await writeWorkout(event)
        default:
            return nil
        }
    }

    private static func writeWorkout(_ event: LedgerEvent) async throws -> UUID? {
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
        try await builder.beginCollection(at: start)
        if !summary.isEmpty {
            try await builder.addMetadata(["trainer_exercises": String(summary.prefix(500))])
        }
        try await builder.endCollection(at: end)
        let finished = try await builder.finishWorkout()
        return finished?.uuid
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

    private static var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for identifier in [HKQuantityTypeIdentifier.bodyMass, .waistCircumference, .dietaryProtein] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        for name in ["nausea", "fatigue", "vomiting", "appetite", "dizziness", "headache", "constipation", "diarrhea", "heartburn", "bloating"] {
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
        if let pressure = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) {
            types.insert(pressure)
        }
        return types
    }
}
