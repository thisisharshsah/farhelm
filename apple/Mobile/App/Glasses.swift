import CompanionKit
import Foundation
import MWDATCore
import MWDATDisplay
import MWDATMockDevice
import Observation
import UIKit

/// Companion on Meta display glasses, by way of this phone: the latest
/// reply from the Mac, the agent's question with its choices, Stop, and a
/// short picker for chats and projects. The phone follows the Mac as it
/// always does (`LiveSession`) and sends what changed to the glasses'
/// display through the Meta Wearables Device Access Toolkit; a tap on the
/// glasses comes back here and goes to the Mac.
///
/// The toolkit is set up the first time the Glasses screen is opened (and
/// at launch from then on), so nothing of it runs for someone without
/// glasses. Without glasses, the toolkit's simulated ones show the same
/// screens in the app (`startPreview`).
@MainActor
@Observable
final class Glasses {
    /// Where things stand with the Meta AI app, which shares the glasses.
    enum Pairing: Equatable {
        case unknown
        case unavailable
        case available
        case registering
        case registered
    }

    private(set) var pairing: Pairing = .unknown
    /// The glasses with a display that this app may use, by name.
    private(set) var names: [String] = []
    /// The display is on and shows Companion.
    private(set) var showing = false
    private(set) var starting = false
    /// The simulated glasses are in use.
    private(set) var previewing = false
    /// The app on the glasses is too old for this one.
    private(set) var needsGlassesUpdate = false
    private(set) var problem: String?

    @ObservationIgnored private let session: LiveSession
    @ObservationIgnored private var wearables: (any WearablesInterface)?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var devicesTask: Task<Void, Never>?

    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayToken: (any AnyListenerToken)?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var mock: (any MockGlasses)?

    /// What the glasses show, and what was last sent to them.
    @ObservationIgnored private var page: GlassPage = .reply
    @ObservationIgnored private var part: Int?
    @ObservationIgnored private var lastTurn: String?
    @ObservationIgnored private var note = ""
    @ObservationIgnored private var projectName = ""
    @ObservationIgnored private var projectChats: [ChatSummary] = []
    @ObservationIgnored private var sent: GlassScreen?
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var stale = false
    @ObservationIgnored private var watching = false

    private static let usedKey = "glassesUsed"

    init(session: LiveSession) {
        self.session = session
        if UserDefaults.standard.bool(forKey: Self.usedKey) { prepare() }
    }

    // MARK: The Meta AI app

    /// The Glasses screen was opened: the toolkit is set up if it was not.
    func opened() {
        prepare()
    }

    /// Sets the toolkit up and follows what it says about the Meta AI app
    /// and the glasses. Nil when it could not be set up (the reason is in
    /// `problem`).
    @discardableResult
    private func prepare() -> (any WearablesInterface)? {
        if let wearables { return wearables }
        do {
            try Wearables.configure()
        } catch {
            report(error)
            return nil
        }
        let wearables = Wearables.shared
        self.wearables = wearables
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        pairing = Self.pairing(wearables.registrationState)
        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self else { return }
                let before = self.pairing
                self.pairing = Self.pairing(state)
                // No longer connected: nothing can be shown.
                if before == .registered, self.pairing == .available || self.pairing == .unavailable {
                    await self.stop()
                }
            }
        }
        devicesTask = Task { [weak self] in
            for await ids in wearables.devicesStream() {
                guard let self else { return }
                self.names = ids.compactMap { wearables.deviceForIdentifier($0) }
                    .filter { $0.supportsDisplay() }
                    .map { $0.nameOrId() }
            }
        }
        return wearables
    }

    private static func pairing(_ state: RegistrationState) -> Pairing {
        switch state {
        case .unavailable: return .unavailable
        case .available: return .available
        case .registering: return .registering
        case .registered: return .registered
        }
    }

    /// Asks the Meta AI app to share the glasses with this app. It opens,
    /// and comes back here with a link (`handle`).
    func connect() async {
        guard let wearables = prepare(), pairing != .registering else { return }
        do {
            try await wearables.startRegistration()
            problem = nil
        } catch {
            report(error)
        }
    }

    func disconnect() async {
        guard let wearables = prepare() else { return }
        await stop()
        do {
            try await wearables.startUnregistration()
            problem = nil
        } catch {
            report(error)
        }
    }

    /// Takes a link the Meta AI app opened this app with. False when the
    /// link is not one of its own (a pairing link for a Mac, say).
    func handle(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return false }
        guard let wearables = prepare() else { return true }
        Task {
            do {
                _ = try await wearables.handleUrl(url)
            } catch {
                self.report(error)
            }
        }
        return true
    }

    /// Opens the Meta AI app where the app on the glasses is updated.
    func updateGlassesApp() async {
        guard let wearables = prepare() else { return }
        do {
            try await wearables.openDATGlassesAppUpdate()
        } catch {
            report(error)
        }
    }

    // MARK: The display

    /// Starts showing Companion on the glasses: the ones the Meta AI app
    /// shares, or `device` when given (the simulated ones).
    func show(on device: DeviceIdentifier? = nil) async {
        guard deviceSession == nil, let wearables = prepare() else { return }
        problem = nil
        needsGlassesUpdate = false
        starting = true
        let selector: any DeviceSelector
        if let device {
            selector = SpecificDeviceSelector(device: device)
        } else {
            selector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
        }
        do {
            let made = try wearables.createSession(deviceSelector: selector)
            deviceSession = made
            let states = made.stateStream()
            let errors = made.errorStream()
            sessionTask = Task { [weak self] in
                for await state in states {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .started: self.addDisplay(to: made)
                    case .stopping: self.showing = false
                    case .stopped: self.clear()
                    default: break
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.clear()
            }
            errorTask = Task { [weak self] in
                for await error in errors {
                    guard let self, !Task.isCancelled else { return }
                    self.starting = false
                    self.report(error)
                }
            }
            // Glasses that are off or not worn never start their display.
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled, self.deviceSession === made, !self.showing else { return }
                made.stop()
                self.clear()
                self.problem = "The glasses' display did not start. Check that the glasses are on, worn and connected in the Meta AI app."
            }
            try made.start()
        } catch {
            clear()
            report(error)
        }
    }

    private func addDisplay(to made: DeviceSession) {
        guard display == nil else { return }
        do {
            let added = try made.addDisplay()
            let (states, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            displayToken = added.statePublisher.listen { state in
                continuation.yield(state)
            }
            displayTask = Task { [weak self] in
                for await state in states {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .starting:
                        break
                    case .started:
                        self.deadline?.cancel()
                        self.deadline = nil
                        self.starting = false
                        self.showing = true
                        self.watch()
                        await self.push(again: true)
                    case .stopping:
                        self.showing = false
                    case .stopped:
                        self.showing = false
                        self.displayToken = nil
                        self.display = nil
                        continuation.finish()
                        self.deviceSession?.stop()
                    }
                }
            }
            added.start()
            display = added
        } catch {
            made.stop()
            clear()
            report(error)
        }
    }

    /// Stops showing on the glasses, and waits (a moment at most) until
    /// they have let go.
    func stop() async {
        guard let made = deviceSession else {
            clear()
            return
        }
        let states = made.stateStream()
        if let display { display.stop() } else { made.stop() }
        if made.state != .stopped {
            let waiting = Task {
                for await state in states where state == .stopped { break }
            }
            let limit = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                waiting.cancel()
            }
            await waiting.value
            limit.cancel()
        }
        clear()
    }

    private func clear() {
        showing = false
        starting = false
        deadline?.cancel()
        deadline = nil
        displayTask?.cancel()
        displayTask = nil
        displayToken = nil
        display = nil
        errorTask?.cancel()
        errorTask = nil
        deviceSession = nil
        sessionTask?.cancel()
        sessionTask = nil
        sent = nil
    }

    // MARK: What is shown

    /// The screen for what the Mac says now.
    private func screenNow() -> GlassScreen {
        let latest = session.turns.last
        // Another reply starts at its own beginning (or follows its end).
        if latest?.id != lastTurn {
            lastTurn = latest?.id
            part = nil
        }
        if !session.isLive, session.turns.isEmpty {
            let words: String
            switch session.link {
            case .failed(let why): words = why
            case .connecting: words = "Reaching your Mac…"
            default: words = "Not connected to a Mac. Open Companion on this phone."
            }
            return GlassScreen(heading: "Companion", text: words)
        }
        switch page {
        case .reply:
            return .reply(meta: session.meta, latest: latest, part: part,
                          note: note.isEmpty && !session.isLive ? "Reconnecting" : note)
        case .chats:
            return .chats(session.chats, heading: "Chats", open: session.meta.chat, back: [GlassScreen.latestKey])
        case .projects:
            return .projects(session.projects)
        case .project:
            return .chats(projectChats, heading: projectName.isEmpty ? "Project" : projectName, open: session.meta.chat,
                          back: [GlassScreen.Key(label: "Projects", action: .show(.projects), quiet: true),
                                 GlassScreen.latestKey])
        }
    }

    /// Sends the screen to the glasses when it differs from the one they
    /// have (or `again`). A reply being written changes many times a
    /// second; the display is sent to less often than that, and what
    /// changed meanwhile goes with the next send.
    private func push(again: Bool = false) async {
        guard let display, showing else { return }
        if sending {
            stale = true
            return
        }
        sending = true
        defer { sending = false }
        var force = again
        repeat {
            stale = false
            let screen = screenNow()
            if force || screen != sent {
                do {
                    try await display.send(screen.view { [weak self] action in
                        Task { @MainActor in await self?.act(action) }
                    })
                    sent = screen
                    problem = nil
                } catch {
                    report(error)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            force = false
        } while stale && showing
    }

    /// Sends again whenever what the Mac says changes, while showing.
    private func watch() {
        guard !watching else { return }
        watching = true
        withObservationTracking {
            _ = session.meta
            _ = session.turns
            _ = session.chats
            _ = session.projects
            _ = session.link
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watching = false
                guard self.showing else { return }
                self.watch()
                await self.push()
            }
        }
    }

    /// A tap on the glasses.
    private func act(_ action: GlassAction) async {
        note = ""
        do {
            switch action {
            case .say(let words):
                try await session.send(words)
            case .stop:
                try await session.stopWork()
            case .part(let index):
                part = index
            case .show(let next):
                page = next
                if next != .reply { await session.refreshChats() }
            case .project(let id):
                let list = try await session.projectChats(id)
                projectName = list.name
                projectChats = list.chats
                page = .project
            case .open(let id):
                try await session.open(id)
                page = .reply
            }
        } catch {
            note = "That did not go through"
        }
        await push()
    }

    // MARK: Without glasses

    /// Pairs the toolkit's simulated display glasses and shows on them. The
    /// same session and the same taps as on real glasses; `previewView` is
    /// their display.
    func startPreview() async {
        guard mock == nil, let wearables = prepare() else { return }
        await stop()
        let kit = MockDeviceKit.shared
        kit.enable()
        do {
            let glasses = try kit.pairGlasses(model: .metaRayBanDisplay)
            mock = glasses
            glasses.powerOn()
            glasses.don()
            try await waitUntilReady(glasses.deviceIdentifier, wearables)
            previewing = true
            await show(on: glasses.deviceIdentifier)
        } catch {
            report(error)
            await stopPreview()
        }
    }

    func stopPreview() async {
        await stop()
        let kit = MockDeviceKit.shared
        if let mock { await kit.unpairDevice(mock) }
        mock = nil
        previewing = false
        if kit.isEnabled { await kit.disable() }
    }

    /// The simulated glasses' display, to put on the phone's screen.
    func previewView() -> UIView? {
        mock?.services.display.createPreviewView()
    }

    private func waitUntilReady(_ id: DeviceIdentifier, _ wearables: any WearablesInterface) async throws {
        for _ in 0..<60 {
            if let device = wearables.deviceForIdentifier(id), device.linkState == .connected,
               device.compatibility() == .compatible {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Problem(errorDescription: "The simulated glasses did not connect.")
    }

    // MARK: Problems

    private struct Problem: LocalizedError {
        var errorDescription: String?
    }

    private func report(_ error: any Error) {
        if (error as? DeviceSessionError) == .datAppOnTheGlassesUpdateRequired { needsGlassesUpdate = true }
        problem = Self.words(error)
    }

    /// An error in words for the screen.
    private static func words(_ error: any Error) -> String {
        if let text = (error as? any LocalizedError)?.errorDescription, !text.isEmpty { return text }
        return error.localizedDescription
    }
}