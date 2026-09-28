import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var outbox = OutboxStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if !model.reachable && outbox.items.count > 0 {
                Text("\(outbox.items.count) update\(outbox.items.count == 1 ? "" : "s") on this phone")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.orange.opacity(0.25))
            }
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sun.max") }
                MealView()
                    .tabItem { Label("Meal", systemImage: "fork.knife") }
                WorkoutView()
                    .tabItem { Label("Workout", systemImage: "dumbbell") }
                DoctorView()
                    .tabItem { Label("Doctor", systemImage: "cross.case") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
        .task { await model.refresh() }
    }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var planExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CollapsibleMarkdown(title: "Plan", text: model.planText, expanded: $planExpanded)
                }
                Section("Weigh-in") {
                    TextField("Pounds", text: $model.weightText)
                        .keyboardType(.decimalPad)
                    Button("Save weight") { Task { await model.logWeight() } }
                }
                Section("Trainer") {
                    TextField("Note", text: $model.note, axis: .vertical)
                    Button(model.noteBusy ? "Waiting for the trainer…" : "Send note") {
                        Task { await model.sendNote() }
                    }
                    .disabled(model.noteBusy)
                    if !model.noteReply.isEmpty {
                        MarkdownText(text: model.noteReply)
                    }
                    if let url = AppSettings.telegramURL() {
                        Link("Open in Telegram", destination: url)
                    } else {
                        Text("Set the Telegram bot username in Settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Sync Apple Health") { Task { await model.syncHealth() } }
                    if !model.status.isEmpty { Text(model.status) }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("Today")
            .refreshable { await model.refresh() }
        }
    }
}

struct MealView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var plate: UIImage?
    @State private var labelImage: UIImage?
    @State private var cameraTarget: PhotoTarget?
    @State private var libraryTarget: PhotoTarget?

    enum PhotoTarget: Identifiable, Equatable {
        case plate, label
        var id: Int { self == .plate ? 0 : 1 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Estimate") {
                    TextField("What you ate, in your own words", text: $text, axis: .vertical)
                }
                Section("Plate") {
                    imageRow(plate)
                    Button("Camera") { openCamera(.plate) }
                    Button("Library") { libraryTarget = .plate }
                }
                Section("Nutrition label") {
                    imageRow(labelImage)
                    Button("Camera") { openCamera(.label) }
                    Button("Library") { libraryTarget = .label }
                }
                Button("Save meal") { Task { await save() } }
                if !model.status.isEmpty { Text(model.status) }
            }
            .dismissibleKeyboard()
            .navigationTitle("Meal")
            .sheet(item: $cameraTarget) { target in
                CameraPicker { image in assign(image, to: target) }
            }
            .sheet(item: $libraryTarget) { target in
                LibraryPicker { image in assign(image, to: target) }
            }
        }
    }

    @ViewBuilder
    private func imageRow(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
        }
    }

    private func openCamera(_ target: PhotoTarget) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            model.status = "This device has no camera. Use the photo library."
            return
        }
        cameraTarget = target
    }

    private func assign(_ image: UIImage, to target: PhotoTarget) {
        if target == .plate { plate = image } else { labelImage = image }
    }

    private func save() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || plate != nil || labelImage != nil else {
            model.status = "Add a photo or a few words."
            return
        }
        do {
            try await SyncService.saveMeal(
                text: trimmed,
                plate: plate?.jpegData(compressionQuality: 0.7),
                label: labelImage?.jpegData(compressionQuality: 0.7)
            )
            text = ""
            plate = nil
            labelImage = nil
            await model.refresh()
            model.status = model.reachable ? "Meal saved. The trainer will read it." : "Meal is waiting on this phone."
        } catch {
            model.status = error.localizedDescription
        }
    }
}

struct WorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @State private var planExpanded = false
    @State private var started = false
    @State private var rows: [SessionExercise] = []
    @State private var change = ""
    @State private var confirmFinish = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CollapsibleMarkdown(title: "Prescribed", text: model.planText, expanded: $planExpanded)
                }
                if !started {
                    Section {
                        Button("Begin workout") { begin() }
                            .disabled(model.planExercises.isEmpty)
                        if model.planExercises.isEmpty {
                            Text("This plan has no exercises yet. Tell the trainer what you want to do.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Change the plan") {
                    TextField("No gym, bodyweight only", text: $change, axis: .vertical)
                    Button(model.planNoteBusy ? "Waiting for the trainer…" : "Send") {
                        let text = change
                        Task {
                            await model.sendPlanNote(text, clear: { change = "" }) {
                                if !started { rows = [] }
                            }
                        }
                    }
                    .disabled(model.planNoteBusy)
                    if !model.planNoteReply.isEmpty {
                        MarkdownText(text: model.planNoteReply)
                    }
                }
                if started {
                    Section("Exercises") {
                        ForEach($rows) { $row in
                            ExerciseRow(row: $row)
                        }
                    }
                    Section {
                        Button("Finish workout") { confirmFinish = true }
                    }
                }
                if !model.status.isEmpty { Text(model.status) }
            }
            .dismissibleKeyboard()
            .navigationTitle("Workout")
            .alert("Finish workout?", isPresented: $confirmFinish) {
                Button("Finish") { Task { await finish() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(finishMessage)
            }
        }
    }

    private var finishMessage: String {
        let open = rows.filter { $0.mark == .pending }.count
        if open == 0 { return "Save this session." }
        return "\(open) still unmarked will be saved as skipped."
    }

    private func begin() {
        planExpanded = false
        started = true
        rows = model.planExercises.map {
            SessionExercise(name: $0.name, prescribed: $0.prescribed)
        }
    }

    private func finish() async {
        for index in rows.indices where rows[index].mark == .pending {
            rows[index].mark = .skipped
        }
        var performed: [[String: Any]] = []
        var skipped: [String] = []
        for row in rows {
            if row.mark == .skipped {
                skipped.append(row.name)
                continue
            }
            var set: [String: Any] = ["reps": Int(row.reps) ?? 0]
            if let rir = Double(row.rir) { set["rir"] = rir }
            var exercise: [String: Any] = [
                "name": row.name,
                "prescribed": row.prescribed,
                "sets": [set],
            ]
            if let load = Double(row.load) { exercise["load_lb"] = load }
            performed.append(exercise)
        }
        do {
            try await SyncService.saveWorkout(
                exercises: performed,
                durationMin: 45,
                location: "unspecified",
                prescribedText: model.planText,
                skipped: skipped
            )
            started = false
            rows = []
            await model.refresh()
            model.status = model.reachable ? "Workout saved." : "Workout is waiting on this phone."
        } catch {
            model.status = error.localizedDescription
        }
    }
}

private struct SessionExercise: Identifiable {
    let id = UUID()
    var name: String
    var prescribed: String
    var mark: Mark = .pending
    var load = ""
    var reps = ""
    var rir = ""
    var open = false

    enum Mark {
        case pending, done, skipped
    }
}

private struct ExerciseRow: View {
    @Binding var row: SessionExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                row.open.toggle()
            } label: {
                HStack {
                    Text(row.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)
            if row.open {
                if !row.prescribed.isEmpty {
                    Text(row.prescribed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Load, pounds", text: $row.load)
                    .keyboardType(.decimalPad)
                TextField("Reps", text: $row.reps)
                    .keyboardType(.numberPad)
                TextField("Reps in reserve", text: $row.rir)
                    .keyboardType(.decimalPad)
                HStack {
                    Button("Complete") {
                        row.mark = .done
                        row.open = false
                    }
                    .disabled(Int(row.reps) == nil)
                    Button("Skip") {
                        row.mark = .skipped
                        row.open = false
                    }
                }
            }
        }
        .listRowBackground(color.opacity(0.22))
    }

    private var color: Color {
        switch row.mark {
        case .pending: .yellow
        case .done: .green
        case .skipped: .red
        }
    }
}

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var prompt = ""
    @State private var share = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
                Button("Build summary prompt") { Task { await build() } }
                if !prompt.isEmpty {
                    Text(verbatim: prompt)
                        .font(.footnote)
                        .lineLimit(18)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Share sends the full prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Share") { share = true }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("Doctor visit")
            .sheet(isPresented: $share) {
                ShareSheet(items: [prompt])
            }
        }
    }

    private func build() async {
        let intervalStart = Calendar.current.startOfDay(for: start)
        let intervalEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
        var doses = ""
        if model.reachable, let client = try? SyncService.client() {
            doses = (try? await client.doses(from: intervalStart, to: intervalEnd)) ?? ""
        }
        do {
            prompt = try await DoctorSummary.prompt(from: intervalStart, to: intervalEnd, doseLines: doses)
        } catch {
            model.status = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scanning = false
    @State private var confirmCleanup = false
    @State private var cleaning = false
    @State private var cleanupMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup code") {
                    Button("Scan setup code") { scanning = true }
                    Text("Or scan the ledger setup page with the Camera app. The address, token, and Telegram bot fill in here. You can still edit them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Ledger address", text: $model.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Ledger token", text: $model.token)
                TextField("Telegram bot username", text: $model.botUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { Task { await model.refresh() } }
                Text("The address stays on this phone. It is not part of the app source.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Section("Apple Health") {
                    Button(cleaning ? "Looking for extra entries…" : "Remove duplicate Health entries") {
                        confirmCleanup = true
                    }
                    .disabled(cleaning)
                    Text("Finds repeated weights, meals, sleep, symptoms, and workouts this app wrote, and deletes the extras. A matching entry from another app is left in place.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !cleanupMessage.isEmpty {
                        Text(cleanupMessage)
                            .font(.footnote)
                    }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("Settings")
            .alert("Remove extra Health entries?", isPresented: $confirmCleanup) {
                Button("Remove extras", role: .destructive) {
                    Task { await removeDuplicateHealthEntries() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("One copy of each repeated value stays. Entries from other apps are not deleted.")
            }
            .sheet(isPresented: $scanning) {
                ZStack(alignment: .topTrailing) {
                    SetupScanner { code in
                        scanning = false
                        if SetupLink.apply(code: code) {
                            model.reloadSettings()
                            Task { await model.refresh() }
                        } else {
                            model.status = "That code is not a setup code."
                        }
                    }
                    Button("Cancel") { scanning = false }
                        .padding()
                }
                .ignoresSafeArea()
            }
        }
    }

    private func removeDuplicateHealthEntries() async {
        cleaning = true
        defer { cleaning = false }
        do {
            try await HealthWriter.requestAccess()
            let removed = try await HealthWriter.removeDuplicates()
            cleanupMessage = removed == 0 ? "No extra entries." : "Removed \(removed) extra \(removed == 1 ? "entry" : "entries")."
        } catch {
            cleanupMessage = error.localizedDescription
        }
    }
}

private extension View {
    func dismissibleKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                }
            }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct LibraryPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: LibraryPicker
        init(_ parent: LibraryPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
