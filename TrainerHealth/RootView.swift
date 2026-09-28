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

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    Text(model.planText.isEmpty ? "No plan stored yet." : model.planText)
                        .font(.body)
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
                        Text(model.noteReply)
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
    @State private var name = ""
    @State private var prescribed = ""
    @State private var load = ""
    @State private var reps = ""
    @State private var rir = ""
    @State private var exercises: [[String: Any]] = []
    @State private var duration = "45"
    @State private var location = "gym"

    var body: some View {
        NavigationStack {
            Form {
                Section("Prescribed") {
                    Text(model.planText.isEmpty ? "No plan stored yet." : model.planText)
                }
                Section("Performed set") {
                    TextField("Exercise", text: $name)
                    TextField("Prescribed load or note", text: $prescribed)
                    TextField("Load you used, pounds", text: $load).keyboardType(.decimalPad)
                    TextField("Reps you did", text: $reps).keyboardType(.numberPad)
                    TextField("Reps in reserve", text: $rir).keyboardType(.decimalPad)
                    Button("Add set") { addSet() }
                }
                Section("This session") {
                    if exercises.isEmpty {
                        Text("No performed sets yet.")
                    } else {
                        ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                            VStack(alignment: .leading) {
                                Text(exercise["name"] as? String ?? "Set").font(.headline)
                                Text("Prescribed: \(exercise["prescribed"] as? String ?? "")")
                                    .foregroundStyle(.secondary)
                                Text(performedLine(exercise))
                            }
                        }
                    }
                    TextField("Minutes", text: $duration).keyboardType(.numberPad)
                    TextField("Location", text: $location)
                    Button("Save workout") { Task { await save() } }
                }
                if !model.status.isEmpty { Text(model.status) }
            }
            .navigationTitle("Workout")
        }
    }

    private func addSet() {
        guard !name.isEmpty, let reps = Int(reps) else { return }
        var set: [String: Any] = ["reps": reps]
        if let rir = Double(rir) { set["rir"] = rir }
        var exercise: [String: Any] = [
            "name": name,
            "prescribed": prescribed,
            "sets": [set],
        ]
        if let load = Double(load) { exercise["load_lb"] = load }
        exercises.append(exercise)
        self.reps = ""
        self.rir = ""
    }

    private func performedLine(_ exercise: [String: Any]) -> String {
        let load = exercise["load_lb"] as? Double
        let sets = exercise["sets"] as? [[String: Any]] ?? []
        let reps = sets.first?["reps"] as? Int
        let rir = sets.first?["rir"] as? Double
        let loadText = load.map { "\($0) lb" } ?? "bodyweight"
        let rirText = rir.map { ", \($0) in reserve" } ?? ""
        return "Performed: \(loadText) × \(reps.map(String.init) ?? "?")\(rirText)"
    }

    private func save() async {
        guard !exercises.isEmpty else {
            model.status = "Add at least one set."
            return
        }
        do {
            try await SyncService.saveWorkout(
                exercises: exercises,
                durationMin: Double(duration) ?? 45,
                location: location,
                prescribedText: model.planText
            )
            exercises = []
            await model.refresh()
            model.status = model.reachable ? "Workout saved." : "Workout is waiting on this phone."
        } catch {
            model.status = error.localizedDescription
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
                    Text(prompt).font(.footnote)
                    Button("Share") { share = true }
                }
            }
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
            }
            .navigationTitle("Settings")
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
