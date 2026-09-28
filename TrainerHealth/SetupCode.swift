import AVFoundation
import SwiftUI

enum SetupLink {
    static func apply(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "trainerhealth", url.host?.lowercased() == "setup" else {
            return false
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let base = value("url")
        let token = value("token")
        guard base.hasPrefix("https://") || base.hasPrefix("http://"), !token.isEmpty else { return false }
        AppSettings.baseURLString = base
        AppSettings.token = token
        let bot = value("bot")
        if !bot.isEmpty {
            AppSettings.botUsername = bot
        }
        return true
    }

    static func apply(code: String) -> Bool {
        guard let url = URL(string: code) else { return false }
        return apply(url)
    }
}

struct SetupScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() }
                }
            }
        default:
            break
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !finished,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue
        else { return }
        finished = true
        session.stopRunning()
        onCode?(code)
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
}
