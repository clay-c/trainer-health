import AppIntents
import Foundation

struct LogWeightIntent: AppIntent {
    static var title: LocalizedStringResource = "Log body weight"
    static var description = IntentDescription("Save a weigh-in to the training ledger.")

    @Parameter(title: "Pounds")
    var pounds: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SyncService.saveWeight(pounds: pounds)
        if await SyncService.reachable() {
            return .result(dialog: "Saved \(pounds) lb.")
        }
        return .result(dialog: "The ledger is not reachable. \(pounds) lb is waiting on this phone.")
    }
}

struct LogMealEstimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a meal estimate"
    static var description = IntentDescription("Save a short meal note. Photos stay in the app.")

    @Parameter(title: "What you ate")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SyncService.saveMealText(text)
        if await SyncService.reachable() {
            return .result(dialog: "Meal saved.")
        }
        return .result(dialog: "The ledger is not reachable. The meal is waiting on this phone.")
    }
}

struct LogSetIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a set"
    static var description = IntentDescription("Save one completed set.")

    @Parameter(title: "Exercise") var name: String
    @Parameter(title: "Load in pounds") var load: Double
    @Parameter(title: "Reps") var reps: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let exercise: [String: Any] = [
            "name": name,
            "load_lb": load,
            "sets": [["reps": reps]],
        ]
        try await SyncService.saveWorkout(exercises: [exercise], durationMin: 0, location: "unspecified")
        if await SyncService.reachable() {
            return .result(dialog: "Saved \(name).")
        }
        return .result(dialog: "The ledger is not reachable. The set is waiting on this phone.")
    }
}

struct ShowTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Show today's workout"
    static var description = IntentDescription("Read the current plan.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if await SyncService.reachable() {
            let text = try await SyncService.planText()
            return .result(value: text)
        }
        return .result(value: SyncService.cachedPlan())
    }
}

struct SyncHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Health"
    static var description = IntentDescription("Copy stored ledger rows into Health.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = try await SyncService.syncHealth()
        return .result(dialog: "Looked at \(count) stored rows.")
    }
}

struct DoctorSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Doctor summary prompt"
    static var description = IntentDescription("Build a prompt from Health for a date range.")

    @Parameter(title: "From") var start: Date
    @Parameter(title: "Through") var end: Date

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let intervalStart = Calendar.current.startOfDay(for: start)
        let intervalEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
        var doses = ""
        if await SyncService.reachable(), let client = try? SyncService.client() {
            doses = (try? await client.doses(from: intervalStart, to: intervalEnd)) ?? ""
        }
        let text = try await DoctorSummary.prompt(from: intervalStart, to: intervalEnd, doseLines: doses)
        return .result(value: text)
    }
}

struct TrainerShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogWeightIntent(),
            phrases: ["Log my weight in \(.applicationName)"],
            shortTitle: "Log weight",
            systemImageName: "scalemass"
        )
        AppShortcut(
            intent: LogMealEstimateIntent(),
            phrases: ["Log a meal in \(.applicationName)"],
            shortTitle: "Log meal",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: LogSetIntent(),
            phrases: ["Log a set in \(.applicationName)"],
            shortTitle: "Log set",
            systemImageName: "dumbbell"
        )
        AppShortcut(
            intent: ShowTodayIntent(),
            phrases: ["Show the workout for today in \(.applicationName)"],
            shortTitle: "Today's workout",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: SyncHealthIntent(),
            phrases: ["Sync \(.applicationName) to Health"],
            shortTitle: "Sync Health",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: DoctorSummaryIntent(),
            phrases: ["Make a doctor summary in \(.applicationName)"],
            shortTitle: "Doctor summary",
            systemImageName: "cross.case"
        )
    }
}
