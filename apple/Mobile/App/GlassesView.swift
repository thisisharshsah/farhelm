import CompanionDesign
import SwiftUI
import UIKit

/// The eyeglasses button beside the Macs menu: opens the Glasses screen.
/// It is tinted while the glasses show Companion.
struct GlassesButton: View {
    @Environment(Glasses.self) private var glasses
    @State private var open = false

    private var palette: Palette { Design.palette() }

    var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: "eyeglasses")
                .textRole(.caption, .primary)
                .foregroundStyle(glasses.showing ? palette.accent : palette.ink.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Glasses")
        .sheet(isPresented: $open) {
            NavigationStack { GlassesView() }
        }
    }
}

/// Companion on Meta display glasses: connect through the Meta AI app,
/// start and stop showing on the glasses, and, without glasses, the
/// toolkit's simulated ones shown here.
struct GlassesView: View {
    @Environment(Glasses.self) private var glasses
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    private var palette: Palette { Design.palette() }

    var body: some View {
        List {
            if !glasses.previewing {
                Section {
                    LabeledContent("Meta AI app", value: pairingText)
                    ForEach(glasses.names, id: \.self) { name in
                        Label(name, systemImage: "eyeglasses")
                    }
                    if glasses.pairing == .registered {
                        Button("Disconnect", role: .destructive) {
                            run { await glasses.disconnect() }
                        }
                        .disabled(busy)
                    } else {
                        Button("Connect Through Meta AI") {
                            run { await glasses.connect() }
                        }
                        .disabled(busy || glasses.pairing == .registering)
                    }
                } footer: {
                    Text("Companion reaches the glasses through the Meta AI app on this phone. Connecting opens it, and it comes back here.")
                }
            }

            Section {
                if glasses.showing && !glasses.previewing {
                    Button("Stop Showing on Glasses") {
                        run { await glasses.stop() }
                    }
                    .disabled(busy)
                } else {
                    Button {
                        run { await glasses.show() }
                    } label: {
                        HStack {
                            Text("Show Companion on Glasses")
                            Spacer()
                            if glasses.starting && !glasses.previewing { ProgressView() }
                        }
                    }
                    .disabled(busy || glasses.previewing || glasses.starting || glasses.pairing != .registered)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("The latest reply from your Mac, the agent's question with its choices, Stop, and a short list of chats and projects.")
            }

            Section {
                if glasses.previewing {
                    GlassPreview(glasses: glasses)
                        .aspectRatio(1, contentMode: .fit)
                        // The glasses' display is dark whatever the phone's look is.
                        .background(Design.Fill.content.style)
                        .environment(\.colorScheme, .dark)
                        .clipShape(Design.Radius.shape(Design.Radius.card))
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                        .accessibilityLabel("Simulated glasses display")
                    Button("Stop Preview") {
                        run { await glasses.stopPreview() }
                    }
                    .disabled(busy)
                } else {
                    Button("Preview Without Glasses") {
                        run { await glasses.startPreview() }
                    }
                    .disabled(busy || glasses.showing || glasses.starting)
                }
            } header: {
                Text("Without glasses")
            } footer: {
                Text("Simulated display glasses from Meta's toolkit, shown here: the same screens and the same taps as on real glasses.")
            }

            if let problem = glasses.problem {
                Section {
                    Text(problem)
                        .font(Design.TextRole.caption.font)
                        .foregroundStyle(palette.rose)
                    if glasses.needsGlassesUpdate {
                        Button("Update the App on the Glasses") {
                            run { await glasses.updateGlassesApp() }
                        }
                    }
                }
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { glasses.opened() }
        // The simulated glasses are only seen here: they go with the screen.
        .onDisappear {
            if glasses.previewing {
                Task { await glasses.stopPreview() }
            }
        }
    }

    private var pairingText: String {
        switch glasses.pairing {
        case .unknown: return "Checking…"
        case .unavailable: return "Not available"
        case .available: return "Not connected"
        case .registering: return "Connecting…"
        case .registered: return "Connected"
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

/// The simulated glasses' display.
private struct GlassPreview: UIViewRepresentable {
    let glasses: Glasses

    func makeUIView(context: Context) -> UIView {
        glasses.previewView() ?? UIView()
    }

    func updateUIView(_ view: UIView, context: Context) {}
}