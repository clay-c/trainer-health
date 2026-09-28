import Foundation
import HealthKit

enum DoctorSummary {
    static func prompt(from start: Date, to end: Date, doseLines: String) async throws -> String {
        try await HealthWriter.requestAccess()
        let store = HealthWriter.store
        let weights = try await quantities(.bodyMass, unit: .pound(), from: start, to: end, store: store)
        let protein = try await quantities(.dietaryProtein, unit: .gram(), from: start, to: end, store: store)
        let waist = try await quantities(.waistCircumference, unit: .meterUnit(with: .centi), from: start, to: end, store: store)
        let heart = try await heartRateLines(from: start, to: end, store: store)
        let steps = try await stepTotal(from: start, to: end, store: store)
        let pressure = try await bloodPressure(from: start, to: end, store: store)
        let sleep = try await sleepHours(from: start, to: end, store: store)
        let workouts = try await workoutLines(from: start, to: end, store: store)

        var lines = [
            "Draft a factual summary a patient can hand to a clinician at a checkup.",
            "Use only the measurements below. If a day or a measure is missing, say so. Do not invent numbers, diagnoses, or dose changes.",
            "",
            "Window: \(day(start)) through \(day(end))",
            "",
            "Body mass (lb):",
            weights.isEmpty ? "- none" : weights,
            "",
            "Waist (cm):",
            waist.isEmpty ? "- none" : waist,
            "",
            "Dietary protein (g):",
            protein.isEmpty ? "- none" : protein,
            "",
            "Sleep (hours, as recorded):",
            sleep.isEmpty ? "- none" : sleep,
            "",
            "Blood pressure:",
            pressure.isEmpty ? "- none" : pressure,
            "",
            "Heart rate (beats per minute, daily low / average / high):",
            heart.isEmpty ? "- none" : heart,
            "",
            "Steps in the window: \(steps.map { String(Int($0)) } ?? "not available")",
            "",
            "Workouts:",
            workouts.isEmpty ? "- none" : workouts,
        ]
        if !doseLines.isEmpty {
            lines.append("")
            lines.append("Medication doses recorded outside Apple Health:")
            lines.append(doseLines)
        }
        return lines.joined(separator: "\n")
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func quantities(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        store: HKHealthStore
    ) async throws -> String {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return "" }
        let samples = try await samples(type: type, from: start, to: end, store: store)
        return samples.compactMap { sample -> String? in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            let value = quantity.quantity.doubleValue(for: unit)
            return "- \(day(quantity.startDate)) \(String(format: "%.1f", value))"
        }.joined(separator: "\n")
    }

    private static func samples(type: HKSampleType, from start: Date, to end: Date, store: HKHealthStore) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    private static func stepTotal(from start: Date, to end: Date, store: HKHealthStore) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .cumulativeSum
            ) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()))
            }
            store.execute(query)
        }
    }

    private static func bloodPressure(from start: Date, to end: Date, store: HKHealthStore) async throws -> String {
        guard let type = HKCorrelationType.correlationType(forIdentifier: .bloodPressure),
              let systolic = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolic = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else { return "" }
        let rows = try await samples(type: type, from: start, to: end, store: store)
        return rows.compactMap { sample -> String? in
            guard let correlation = sample as? HKCorrelation else { return nil }
            let sys = (correlation.objects(for: systolic).first as? HKQuantitySample)?
                .quantity.doubleValue(for: .millimeterOfMercury())
            let dia = (correlation.objects(for: diastolic).first as? HKQuantitySample)?
                .quantity.doubleValue(for: .millimeterOfMercury())
            guard let sys, let dia else { return nil }
            return "- \(day(correlation.startDate)) \(Int(sys))/\(Int(dia))"
        }.joined(separator: "\n")
    }

    private static func sleepHours(from start: Date, to end: Date, store: HKHealthStore) async throws -> String {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return "" }
        let rows = try await samples(type: type, from: start, to: end, store: store)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var totals: [String: Double] = [:]
        var order: [String] = []
        for sample in rows {
            guard let category = sample as? HKCategorySample, asleep.contains(category.value) else { continue }
            let key = day(category.startDate)
            if totals[key] == nil { order.append(key) }
            totals[key, default: 0] += category.endDate.timeIntervalSince(category.startDate) / 3600
        }
        return order.map { "- \($0) \(String(format: "%.1f", totals[$0] ?? 0))" }.joined(separator: "\n")
    }

    private static func heartRateLines(from start: Date, to end: Date, store: HKHealthStore) async throws -> String {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return "" }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: [.discreteAverage, .discreteMin, .discreteMax],
                anchorDate: Calendar.current.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var lines: [String] = []
                results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let average = statistics.averageQuantity()?.doubleValue(for: unit),
                          let low = statistics.minimumQuantity()?.doubleValue(for: unit),
                          let high = statistics.maximumQuantity()?.doubleValue(for: unit) else { return }
                    lines.append(
                        "- \(day(statistics.startDate)) low \(Int(low.rounded())) avg \(Int(average.rounded())) high \(Int(high.rounded()))"
                    )
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            store.execute(query)
        }
    }

    private static func workoutLines(from start: Date, to end: Date, store: HKHealthStore) async throws -> String {
        let rows = try await samples(type: HKObjectType.workoutType(), from: start, to: end, store: store)
        return rows.compactMap { sample -> String? in
            guard let workout = sample as? HKWorkout else { return nil }
            let minutes = Int(workout.duration / 60)
            return "- \(day(workout.startDate)) \(workout.workoutActivityType.name) \(minutes) min"
        }.joined(separator: "\n")
    }
}

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .traditionalStrengthTraining: "strength"
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        default: "activity \(rawValue)"
        }
    }
}
