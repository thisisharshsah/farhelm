import Darwin
import Foundation

/// A program the agent runs, started so that macOS does not count it as
/// Companion.
///
/// What `Process` starts belongs to Companion as far as privacy permissions
/// go: it may record the screen, use the microphone and work other apps with
/// the access the person gave Companion, and nothing asks. The agent's
/// commands, and whatever they start in turn (a build script, an install's
/// own scripts), need none of that, and a command written by a model that
/// something misled must not have it. So they start the way Terminal starts
/// a shell: responsible for themselves. A command that does need such access
/// (driving another app through AppleScript, say) is asked about in its own
/// name. The agent's own steps that look at the screen or work other apps
/// run in Companion, behind their approvals, and are not affected.
///
/// The call that does this is not in the public SDK, so it is looked up when
/// a program starts; where it is missing, the program starts as before. The
/// interface is the part of `Process` its callers use.
final class AgentProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String] = []
    var currentDirectoryURL: URL?
    /// Nil means Companion's own environment.
    var environment: [String: String]?
    /// Each a `Pipe`, a `FileHandle`, or nil for /dev/null.
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    /// Starts as Companion's own, with its access, instead of responsible
    /// for itself: only for a folder the person allowed (`ShellAccess`).
    var inheritsAccess = false

    /// Called once, on a thread of its own, when the program has ended.
    var terminationHandler: (@Sendable (AgentProcess) -> Void)? {
        get { state.withLock { handler } }
        set { state.withLock { handler = newValue } }
    }

    private let state = NSCondition()
    private var handler: (@Sendable (AgentProcess) -> Void)?
    private var pid: pid_t = 0
    private var running = false
    private var status: Int32 = 0

    var processIdentifier: Int32 { state.withLock { pid } }
    var isRunning: Bool { state.withLock { running } }
    /// The exit code, or the signal that ended it, as `Process` gives it.
    var terminationStatus: Int32 { state.withLock { status } }

    func run() throws {
        guard let path = executableURL?.path else { throw CocoaError(.fileNoSuchFile) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, so stopping it reaches what it started;
        // signals at their defaults and none blocked, whatever Companion has;
        // and none of Companion's open files but the three given here.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        if !inheritsAccess, let disclaim = Self.disclaim { _ = disclaim(&attributes, 1) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        Self.connect(standardInput, to: STDIN_FILENO, writing: false, in: &actions)
        Self.connect(standardOutput, to: STDOUT_FILENO, writing: true, in: &actions)
        Self.connect(standardError, to: STDERR_FILENO, writing: true, in: &actions)
        if let folder = currentDirectoryURL?.path {
            posix_spawn_file_actions_addchdir_np(&actions, folder)
        }

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        let variables = (environment ?? ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in variables { free(pointer) } }

        var child: pid_t = 0
        let result = posix_spawn(&child, path, &actions, &attributes, argv, variables)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        // This side's copies of the child's ends, closed so a reader sees the
        // end of the output once the program is done (as `Process` does).
        if let pipe = standardInput as? Pipe { try? pipe.fileHandleForReading.close() }
        if let pipe = standardOutput as? Pipe { try? pipe.fileHandleForWriting.close() }
        if let pipe = standardError as? Pipe, pipe !== standardOutput as? Pipe {
            try? pipe.fileHandleForWriting.close()
        }

        state.withLock {
            pid = child
            running = true
        }
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1, errno == EINTR {}
            let signal = raw & 0x7f
            state.lock()
            status = signal == 0 ? (raw >> 8) & 0xff : signal
            running = false
            let ended = handler
            state.broadcast()
            state.unlock()
            ended?(self)
        }
    }

    func waitUntilExit() {
        state.lock()
        while running { state.wait() }
        state.unlock()
    }

    /// Asks the program, and whatever it started, to stop.
    func terminate() {
        let target = state.withLock { running ? pid : 0 }
        guard target > 0 else { return }
        if kill(-target, SIGTERM) != 0 { kill(target, SIGTERM) }
    }

    /// Companion's environment cut down to what a shell and its tools
    /// expect. A provider key Companion was given through the environment
    /// stays behind (security review, M10); the login shell adds the
    /// person's own settings back from their startup files.
    static func plainEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            plainVariables.contains(key) || key.hasPrefix("LC_")
        }
    }

    private static let plainVariables: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "COLORTERM", "TZ",
        "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "DEVELOPER_DIR",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy",
    ]

    private static func connect(_ stream: Any?, to target: Int32, writing: Bool,
                                in actions: inout posix_spawn_file_actions_t?) {
        var descriptor: Int32 = -1
        if let pipe = stream as? Pipe {
            descriptor = writing ? pipe.fileHandleForWriting.fileDescriptor
                : pipe.fileHandleForReading.fileDescriptor
        } else if let handle = stream as? FileHandle {
            descriptor = handle.fileDescriptor
        }
        if descriptor >= 0 {
            posix_spawn_file_actions_adddup2(&actions, descriptor, target)
        } else {
            posix_spawn_file_actions_addopen(&actions, target, "/dev/null", writing ? O_WRONLY : O_RDONLY, 0)
        }
    }

    /// `responsibility_spawnattrs_setdisclaim(attributes, 1)`, as Chromium
    /// and Qt Creator call it; nil where this macOS does not have it.
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let disclaim: Disclaim? = {
        // RTLD_DEFAULT: every image already loaded.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }()
}
