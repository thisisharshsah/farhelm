import CompanionDesign
import CompanionKit
import SwiftUI
import VisionKit

/// Pairing with a Mac: scan the code Companion shows in Settings > Remote
/// (the Camera app works too), or paste the link. Macs found on this
/// network are listed, so it is plain which one to pair with.
struct PairView: View {
    @Environment(MacStore.self) private var store
    @Environment(LiveSession.self) private var session
    @Environment(Discovery.self) private var discovery
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var pasted = ""
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    LoadingMark(state: .thinking, size: Design.Icon.large.width * 2)
                    Text("Pair with your Mac")
                        .textRole(.title)
                        .fontWeight(.semibold)
                    Text("On your Mac, open Companion > Settings > Remote, turn on **Let the Companion app connect**, then scan the code it shows.")
                        .textRole(.body, .secondary)
                }
                .padding(.vertical, Design.Space.xs)
                Button {
                    scanning = true
                } label: {
                    Label("Scan the code", systemImage: "qrcode.viewfinder")
                }
                .disabled(!QRScanner.isAvailable)
            }

            Section {
                TextField("companion://pair?…", text: $pasted, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Design.TextRole.code.font)
                Button("Pair with this link") { pair(pasted) }
                    .disabled(pasted.isEmpty)
            } header: {
                Text("Or paste the link")
            } footer: {
                if let problem { Text(problem).foregroundStyle(Design.Tone.critical.color) }
            }

            if !discovery.found.isEmpty {
                Section {
                    ForEach(discovery.found) { mac in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(mac.name)
                                Text(store.macs.contains { $0.id == mac.id } ? "Paired" : "Scan its code to pair")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("On this network")
                }
            }

            Section {
                Label("To reach your Mac away from its Wi-Fi, turn on Reach this Mac from anywhere in Settings > Remote on the Mac before you scan. Everything then goes through your relay, end to end encrypted.",
                      systemImage: "network")
                    .font(Design.TextRole.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Companion")
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                pair(code)
            }
            .ignoresSafeArea()
        }
    }

    private func pair(_ text: String) {
        guard let mac = PairingLink.parse(text) else {
            problem = "That is not a Companion pairing code. Scan the one in Companion's Settings > Remote."
            return
        }
        problem = nil
        pasted = ""
        store.add(mac)
        session.restart()
        dismiss()
    }
}

/// The camera, reading QR codes, until one is found.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(code) = item, let text = code.payloadStringValue, text.hasPrefix("companion://") {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
