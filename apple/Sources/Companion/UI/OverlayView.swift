import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main glass panel, laid out as a conversation workspace:
/// header, status chips, a compact live transcript, one chat timeline holding
/// both reply and screen turns, and an input bar with the model switcher.
struct OverlayView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var keys = Shortcuts.shared
    @ObservedObject private var usage = UsageStore.shared
    /// The command palette, open over the panel when asked for.
    @ObservedObject private var commands = CommandRegistry.shared
    @FocusState private var inputFocused: Bool
    @State private var showNotes = false
    /// The engine and model picker, open above the chat box.
    @State private var showModels = false
    /// The bar that sets the effort, open above the chat box.
    @State private var showEffort = false
    /// The pointer is over the model button: its card shows.
    @State private var modelHover = false
    /// The sidebar floating open because the pointer is on its button or on
    /// the sidebar itself. It closes when the pointer leaves both.
    /// The pointer is over the conversation.
    @State private var chatHover = false
    /// Heights of the floating top bar and the floating bottom, so the
    /// conversation can leave room for them at its ends.
    @State private var topHeight: CGFloat = 52
    @State private var bottomHeight: CGFloat = 96
    /// The panel's width as it really is, so the columns always fit in it.
    @State private var panelWidth: CGFloat = 560
    /// Renaming the open conversation in the top bar.
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var renameFocused: Bool
    @State private var sidebarPeek = false
    @State private var pointerOnSidebarButton = false
    @State private var pointerOnSidebar = false

    var body: some View {
        VStack(spacing: 0) {
            if app.compact && !app.pillExpanded {
                pill
            } else {
                // The top bar and the chat box float over the conversation,
                // which runs the full height of the panel behind them, the
                // way content passes under a toolbar in a Mac app. Their
                // heights are measured so the conversation can leave room
                // at its ends and nothing is ever hidden for good.
                ZStack(alignment: .top) {
                HStack(spacing: 0) {
                // Pinned, the sidebar takes its own column and the chat
                // sits to the right of it. In code it is on the far right
                // instead, with the chat: see below.
                if app.sidebarPinned, !codeLayout, !app.showSettings {
                    SidebarView()
                        .padding(.top, topHeight)
                        .frame(width: shownSidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    // Drag to give the sidebar more or less room.
                    ColumnDivider(width: { app.sidebarWidth },
                                  direction: 1,
                                  resize: { app.overlay?.dragColumn(left: true, to: $0) },
                                  reset: { app.overlay?.resetColumn(left: true) },
                                  done: { app.saveColumnWidths() })
                }
                // The chat and what sits beside it. In code the two trade
                // places, as in an editor: the workspace (files and the
                // open file) takes the middle and the chat is a column on
                // the right.
                HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                if app.showSettings {
                    SettingsView()
                        .padding(.top, topHeight)
                        .transition(.opacity)
                } else {
                    // Notes, a warning or the setup guide sit below the top
                    // bar; with none of them, the conversation itself runs
                    // up behind it.
                    let fixedAbove = showNotes || app.lastError != nil || setupShown
                    if fixedAbove {
                        Color.clear.frame(height: topHeight)
                    }
                    if showNotes {
                        notesView(app.conversation.record ?? app.conversation.summary ?? "")
                            .frame(height: 190)
                        hairline
                    }
                    if let error = app.lastError {
                        errorBanner(error)
                            .padding(.top, 8)
                    }
                    // What is still missing, with the button that fixes it.
                    if setupShown {
                        SetupGuide()
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, 10)
                    }
                    // The conversation is drawn at the content zoom
                    // (Cmd+Plus, Cmd+Minus, Cmd+0). Its insets are given in
                    // its own, zoomed, measure so it still clears the bars.
                    let zoom = CGFloat(settings.contentZoom)
                    ChatThread(topInset: (fixedAbove ? 6 : topHeight) / zoom,
                               bottomInset: bottomHeight / zoom)
                        .padding(.horizontal, Theme.gutter / zoom)
                        .contentZoom(settings.contentZoom)
                        .frame(maxHeight: .infinity)
                        // The conversation's tools and its context ring
                        // appear at the top right while the pointer is on
                        // the conversation, and stay out of the way
                        // otherwise. A recheck in progress keeps them up.
                        .overlay(alignment: .topTrailing) {
                            if chatHover || app.isRescanning {
                                HStack(spacing: 6) {
                                    ContextMeter(use: app.contextUse, window: ContextBudget.current.window,
                                                 spent: usage.cost(of: usage.records(for: app.conversation.id)))
                                        .padding(.horizontal, 9)
                                        .frame(height: 28)
                                        .background(Capsule().fill(Theme.shade.opacity(0.55)))
                                        .liquidGlass(in: Capsule())
                                    ThreadActions()
                                        .background(Capsule().fill(Theme.shade.opacity(0.55)))
                                }
                                .padding(.trailing, Theme.gutter)
                                .padding(.top, (fixedAbove ? 0 : topHeight) + 8)
                                .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { chatHover = $0 }
                        .animation(.easeOut(duration: 0.15), value: chatHover)
                }
                }
                // The floating bottom: the agent's card, attached files and
                // the chat box.
                if !app.showSettings {
                    VStack(spacing: 0) {
                    actionCard
                        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: app.agentRunning)
                        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: app.pendingApproval?.id)
                        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: app.pendingQuestion?.id)
                        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: app.nextSteps?.steps)
                    // The model picker hangs from a line of no height just
                    // above the chat box and grows upward from it, over the
                    // conversation. It takes no room in the layout, so
                    // opening it moves nothing.
                    Color.clear
                        .frame(height: 0)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottomLeading) {
                            if showModels {
                                ModelPicker(isOpen: $showModels)
                                    .frame(width: 326)
                                    .padding(.leading, Theme.gutter)
                                    .padding(.bottom, 2)
                                    .transition(.opacity.combined(with: .offset(y: 6)))
                            } else if showEffort {
                                EffortBar(isOpen: $showEffort)
                                    .padding(.leading, Theme.gutter)
                                    .padding(.bottom, 2)
                                    .transition(.opacity.combined(with: .offset(y: 6)))
                            } else if modelHover {
                                // Hovering the model button: which engine
                                // answers and what is left of the plan.
                                ModelHoverCard()
                                    .padding(.leading, Theme.gutter)
                                    .padding(.bottom, 2)
                                    .transition(.opacity.combined(with: .offset(y: 4)))
                            }
                        }
                        .animation(.easeOut(duration: 0.16), value: modelHover)
                        .zIndex(2)
                    inputBar
                        .padding(.bottom, 6)
                    }
                    .padding(.top, 14)
                    .background(edgeFade(from: .bottom))
                    .background(measure { if abs($0 - bottomHeight) > 0.5 { bottomHeight = $0 } })
                }
                }
                // When the right column is given the whole panel, the chat
                // steps aside: it keeps its place and its state, takes no
                // room, and comes back the moment it is asked for.
                .frame(width: sideIsFull ? 0 : (codeLayout ? codeChatShown : nil))
                .clipped()
                .opacity(sideIsFull ? 0 : 1)
                .allowsHitTesting(!sideIsFull)
                .environment(\.layoutDirection, .leftToRight)
                // The column on the right: details of the session, the
                // browser, or the workspace.
                if let side = app.sidePanel {
                    if codeLayout, !sideIsFull {
                        // In code the divider sets the chat's width; the
                        // workspace has the rest.
                        ColumnDivider(width: { codeChatShown },
                                      direction: -1,
                                      resize: { app.codeChatWidth = min(max($0, 300), max(300, panelWidth - (app.sidebarPinned ? shownSidebarWidth : 0) - 380)) },
                                      reset: { app.codeChatWidth = 380 },
                                      done: { app.saveColumnWidths() })
                            .padding(.top, topHeight)
                    } else if !sideIsFull {
                        // Drag to give the column more or less room.
                        ColumnDivider(width: { app.width(of: side) },
                                      direction: -1,
                                      resize: { app.overlay?.dragColumn(left: false, to: $0) },
                                      reset: { app.overlay?.resetColumn(left: false) },
                                      done: { app.saveColumnWidths() })
                            .padding(.top, topHeight)
                    }
                    Group {
                        if codeLayout, app.codeDetails, !sideIsFull {
                            // The details sit between the workspace and the
                            // chat; the workspace keeps the rest.
                            HStack(spacing: 0) {
                                SidePanel(mode: side)
                                Rectangle()
                                    .fill(Theme.ink.opacity(0.08))
                                    .frame(width: 1)
                                SessionDetails()
                                    .frame(width: 280)
                            }
                            .environment(\.layoutDirection, .leftToRight)
                        } else {
                            SidePanel(mode: side)
                        }
                    }
                        .padding(.top, topHeight)
                        .frame(width: sideIsFull || codeLayout ? nil : sideWidth(side))
                        .frame(maxWidth: sideIsFull || codeLayout ? .infinity : nil)
                        .environment(\.layoutDirection, .leftToRight)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                }
                // Laid out right to left in code, which is all it takes to
                // put the chat on the right; each column reads left to
                // right as ever.
                .environment(\.layoutDirection, codeLayout ? .rightToLeft : .leftToRight)
                // In code the conversations keep to the chat's side: the
                // workspace has the left and the middle, the chat is on the
                // right, and the list of chats is beyond it at the edge.
                if app.sidebarPinned, codeLayout {
                    // Dragging left gives the sidebar more room here.
                    ColumnDivider(width: { app.sidebarWidth },
                                  direction: -1,
                                  resize: { app.overlay?.dragColumn(left: true, to: $0) },
                                  reset: { app.overlay?.resetColumn(left: true) },
                                  done: { app.saveColumnWidths() })
                        .padding(.top, topHeight)
                    SidebarView()
                        .padding(.top, topHeight)
                        .frame(width: shownSidebarWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                }
                // The floating top: the app bar, and under it the live
                // indicator or a warning when there is one.
                VStack(spacing: 0) {
                    header
                    if !app.showSettings, chipRowNeeded {
                        chipRow
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 10)
                // The top bar is the panel's title bar: drag it to move the
                // panel, double-click it to fill the screen.
                .background(TitleBarArea(zoom: { app.overlay?.toggleZoom() },
                                         minimize: { app.overlay?.setCompact(true) }))
                .background(edgeFade(from: .top))
                .background(measure { if abs($0 - 8 - topHeight) > 0.5 { topHeight = $0 - 8 } })
                }
            }
        }
        .frame(minWidth: isPill ? 240 : 540, maxWidth: .infinity,
               minHeight: isPill ? 44 : 560, maxHeight: .infinity)
        // The command palette drops from the top, over everything. A click
        // anywhere else closes it.
        .overlay(alignment: .top) {
            if commands.paletteOpen, !isPill {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { commands.closePalette() }
                    CommandPalette()
                        .padding(.top, 46)
                        .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: commands.paletteOpen)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { panelWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        // Only a real change redraws the panel.
                        if abs(width - panelWidth) > 0.5 { panelWidth = width }
                    }
            }
        }
        .background {
            ZStack {
                // The panel's base, as the look sets it: how much the desktop
                // behind is blurred, and how far it is deepened so it never
                // competes with the text. (`settings.look` is read so a
                // change redraws this at once.)
                let _ = settings.look
                if Theme.behindBlur > 0 {
                    VisualEffectView(light: Theme.isLight, strength: Theme.behindBlur)
                }
                Theme.shade.opacity(Theme.baseDim(.center))
                Theme.accent.opacity(0.05)
            }
        }
        // Soft colored light in the corners plus a top sheen.
        .overlay(alignment: .topLeading) {
            RadialGradient(colors: [Theme.accent.opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 260)
                .frame(width: 260, height: 260)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            RadialGradient(colors: [Theme.lilac.opacity(0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 240)
                .frame(width: 240, height: 240)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.ink.opacity(0.09), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .allowsHitTesting(false)
        }
        // Hovering the sidebar button floats the conversations over the
        // chat: pick one and it closes, or move away and it closes.
        .overlay(alignment: codeLayout ? .topTrailing : .topLeading) {
            if sidebarPeek, !app.sidebarPinned, !isPill, !app.showSettings {
                // A glass card the full height under the top bar, set in
                // from the edges like the rest of Companion's surfaces.
                SidebarView()
                    .frame(width: 258)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Theme.shade.opacity(0.30)))
                    .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .glassBorder(radius: Theme.cardRadius, tint: Theme.accent)
                    .onHover { inside in
                        pointerOnSidebar = inside
                        if !inside { closePeekSoon() }
                    }
                    // It floats on the side its column would be on.
                    .padding(codeLayout ? .trailing : .leading, 8)
                    .padding(.bottom, 8)
                    .padding(.top, topHeight + 4)
                    .transition(.move(edge: codeLayout ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: sidebarPeek)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: app.sidebarPinned)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: app.sidePanel)
        .onChange(of: app.conversation.id) { _, _ in
            sidebarPeek = false
            if app.sidebarPinned { app.refreshHistory() }
        }
        .clipShape(RoundedRectangle(cornerRadius: isPill ? 18 : Theme.panelRadius, style: .continuous))
        .glassBorder(radius: isPill ? 18 : Theme.panelRadius)
        // The panel springs up as it appears and settles back as it hides;
        // the window itself fades (see OverlayController).
        .scaleEffect(app.panelVisible ? 1 : 0.955, anchor: .top)
        .opacity(app.panelVisible ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: app.panelVisible)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isPill)
        // In compact mode the pill opens while the pointer is on it.
        .onHover { inside in
            app.overlay?.hoverPill(inside)
        }
        // A change of theme redraws everything in the new colors.
        .id("\(settings.appearance)-\(settings.themeTick)")
        .preferredColorScheme(Theme.isLight ? .light : .dark)
        // Moving between the conversation, history and settings is one
        // soft motion, not a jump.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: app.showSettings)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: app.showHistory)
    }

    /// Compact mode, with the pointer away: just the pill.
    private var isPill: Bool { app.compact && !app.pillExpanded }

    /// The pill: what Companion is doing in one line. It opens on hover; a
    /// click (or Cmd+Shift+M) brings the full panel back for good.
    private var pill: some View {
        HStack(spacing: 9) {
            if app.agentRunning {
                LoadingMark(state: app.pendingApproval == nil ? .working : .waiting, size: 14)
            } else if app.isListening {
                PulsingDot(color: Theme.mint)
            } else {
                Circle()
                    .fill(Theme.ink.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .frame(width: 14, height: 14)
            }
            Text(pillText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if app.hasUnseen {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
            }
            if app.agentRunning {
                Button { app.stopAgent() } label: { Chip("Stop", icon: "stop.fill", tint: Theme.rose) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DragHandle())
        .contentShape(Rectangle())
        .onTapGesture { app.overlay?.setCompact(false) }
        .help("Hover to open, click to keep it open (\(keys.label(.pill)))")
    }

    private var pillText: String {
        if app.pendingQuestion != nil { return "Companion has a question" }
        if app.pendingApproval != nil { return "Companion needs your OK" }
        if app.agentRunning { return app.agentStatus ?? "Working" }
        return app.isListening ? app.statusLine : "Companion"
    }

    /// The setup guide is showing: something essential is missing, or the
    /// conversation is new and setup has optional steps left.
    private var setupShown: Bool {
        !settings.setupDismissed
            && (!SetupGuide.essentialsDone
                || app.conversation.turns.isEmpty && app.segments.isEmpty && !setupComplete)
    }

    /// The blur behind a floating bar: full at the panel's edge and fading
    /// out toward the conversation, so what scrolls under it softens away
    /// instead of being cut off at a line.
    private func edgeFade(from edge: VerticalEdge) -> some View {
        let zone: Look.Zone = edge == .top ? .top : .bottom
        let _ = settings.look
        return ZStack {
            if let material = Theme.barMaterial(zone) {
                Rectangle().fill(material)
            }
            Theme.shade.opacity(Theme.barDim(zone))
        }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: 0.62),
                                         .init(color: .clear, location: 1)],
                                 startPoint: edge == .top ? .top : .bottom,
                                 endPoint: edge == .top ? .bottom : .top))
            .allowsHitTesting(false)
    }

    /// The right column's width: its set width when the panel has room, and
    /// whatever is left beside the chat when it does not, so nothing is
    /// ever pushed out of the panel.
    private func sideWidth(_ side: SidePanelMode) -> CGFloat {
        let taken = (app.sidebarPinned ? shownSidebarWidth : 0) + OverlayController.chatLeast
        return min(app.width(of: side), max(OverlayController.sideLeast(side), panelWidth - taken))
    }

    /// The right column has the whole panel and the chat is out of the way.
    private var sideIsFull: Bool { app.sideFull && app.sidePanel != nil && !app.showSettings }
    /// Code with its workspace open: files and editor in the middle, chat
    /// on the right.
    private var codeLayout: Bool { app.codeMode && app.sidePanel == .workspace && !app.showSettings }
    /// The chat column's width in code, kept to what the panel can give.
    private var codeChatShown: CGFloat {
        min(max(app.codeChatWidth, 300), max(300, panelWidth - (app.sidebarPinned ? shownSidebarWidth : 0) - 380))
    }

    /// The pinned sidebar's width: its set width when the panel has room,
    /// less when it does not, down to its narrowest. The panel is never
    /// narrower than its columns at their narrowest, so they always fit.
    private var shownSidebarWidth: CGFloat {
        let other = app.sidePanel.map(OverlayController.sideLeast) ?? 0
        return min(app.sidebarWidth,
                   max(OverlayController.sidebarLeast, panelWidth - OverlayController.chatLeast - other))
    }

    /// Reports a view's height whenever it changes.
    private func measure(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { report(geometry.size.height) }
                .onChange(of: geometry.size.height) { _, height in report(height) }
        }
    }

    /// Closes the floating sidebar once the pointer has left both its
    /// button and the sidebar, with a moment's grace to cross between them.
    private func closePeekSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            if !pointerOnSidebarButton, !pointerOnSidebar {
                sidebarPeek = false
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            WindowControls()
            // The button for the conversations is on the side they open
            // on: the left, or in code the right (at the end of the bar).
            if !codeLayout {
                sidebarButton
            }
            // Every command and, in code, every file, by name. In a
            // narrow panel it leaves the bar; its keys still work.
            if panelWidth >= 640 {
            ToolbarGroup {
            IconButton("magnifyingglass", help: "Go to a file or run a command (⌘P, ⇧⌘P)") {
                commands.openPalette(commands: !app.hasWorkFolder)
            }
            }
            }
            // The two sides of the app, side by side: chat and code. The
            // one in use is colored.
            ToolbarGroup {
            IconButton("bubble.left.and.bubble.right",
                       help: app.codeMode ? "Chat: back to plain conversation" : "Chat",
                       tint: app.codeMode ? nil : Theme.accent) {
                app.setCode(false)
            }
            // Code: files and editor, search, changes with undo, terminal.
            // It works in a folder, so the first click asks for one.
            IconButton("chevron.left.forwardslash.chevron.right",
                       help: "Code: work on a repository. Files and editor, search, changes with undo, terminal.",
                       tint: app.codeMode ? Theme.accent : nil) {
                app.setCode(true)
            }
            }
            VStack(alignment: .leading, spacing: 1) {
                // The name of this conversation. Double-click to rename it.
                if renaming, !app.showSettings {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.96))
                        .focused($renameFocused)
                        .frame(minWidth: 90, maxWidth: 190)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.09)))
                        .glassBorder(radius: 6, tint: Theme.accent)
                        .onSubmit {
                            app.renameConversation(app.conversation.id, to: newName)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused { renaming = false }
                        }
                } else {
                    Text(app.showSettings ? "Settings" : app.conversation.title)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.96))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(app.showSettings ? "Settings" : "\(app.conversation.title). Double-click to rename.")
                        .onTapGesture(count: 2) {
                            guard !app.showSettings else { return }
                            newName = app.conversation.title == Conversation.defaultTitle ? "" : app.conversation.title
                            renaming = true
                            renameFocused = true
                        }
                }
                // What it is doing, or why it did not reply just now. Nothing
                // is shown when there is nothing to say.
                if app.statusLine != "Ready" {
                    Text(app.statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .lineLimit(1)
                        .help(app.statusLine)
                }
            }
            // The name always keeps some room; in a narrow panel it is cut
            // short with an ellipsis and never squeezed out altogether.
            .frame(minWidth: 72, alignment: .leading)
            .layoutPriority(-1)
            // The empty stretch of the top bar is a real title bar area, laid
            // out as a view of its own so it is certain to get the mouse:
            // drag it to move the panel, double-click it to fill the screen.
            TitleBarArea(zoom: { app.overlay?.toggleZoom() },
                         minimize: { app.overlay?.setCompact(true) })
                .frame(minWidth: 8, maxWidth: .infinity)
                .frame(height: 30)
            if !isPill {
                // This conversation's switches: mode, auto-reply, screen
                // watch, notes. Colored means on.
                ToolbarGroup {
                    modeMenu
                    IconButton("sparkles",
                               help: settings.autoSuggest
                                   ? "Auto-reply is on: a reply is drafted when the other person finishes speaking. Click to turn off."
                                   : "Auto-reply is off: replies are drafted only when you ask. Click to turn on.",
                               tint: settings.autoSuggest ? Theme.accent : nil) {
                        settings.autoSuggest.toggle()
                    }
                    IconButton("text.viewfinder",
                               help: settings.autoScreenWatch
                                   ? "Screen watch is on: new questions that appear on your screen are answered. Click to turn off."
                                   : "Screen watch is off: the screen is read only when you ask. Click to turn on.",
                               tint: settings.autoScreenWatch ? Theme.violet : nil) {
                        settings.autoScreenWatch.toggle()
                    }
                    if hasNotesContent {
                        IconButton("note.text",
                                   help: showNotes
                                       ? "Showing the notes. Click to close them."
                                       : "See or update the summary of this conversation so far.",
                                   tint: showNotes ? Theme.accent : nil) {
                            showNotes.toggle()
                        }
                    }
                }
                // What sits beside the chat: a browser, and the session's
                // details (progress, outputs, what was used).
                ToolbarGroup {
                    IconButton("globe",
                               help: app.sidePanel == .browser ? "Close the browser" : "Open the browser beside the chat",
                               tint: app.sidePanel == .browser ? Theme.accent : nil) {
                        app.showSide(app.sidePanel == .browser ? nil : .browser)
                    }
                    // A live dot while this chat's browser has a page open,
                    // so it is plain something is running there even with
                    // the pane closed.
                    .overlay(alignment: .topTrailing) {
                        if app.webRunning.contains(app.conversation.id) {
                            StatusDot(active: true)
                                .padding(4)
                                .allowsHitTesting(false)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    if app.sideFull, app.sidePanel != nil {
                        IconButton("bubble.left.and.text.bubble.right", help: "Show the chat again", tint: Theme.accent) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull = false }
                        }
                    }
                    let detailsOpen = app.codeMode ? app.codeDetails : app.sidePanel == .details
                    IconButton("list.bullet",
                               help: detailsOpen ? "Close the details" : "Progress, outputs and what this session used",
                               tint: detailsOpen ? Theme.accent : nil) {
                        if detailsOpen { app.closeDetails() } else { app.showSide(.details) }
                    }
                }
                // See-through is a button of its own. (A new conversation,
                // Settings and Quit are at the sidebar.)
                ToolbarGroup {
                    // It stays clickable while on, so the same button
                    // turns it off.
                    IconButton("cursorarrow.rays",
                               help: app.clickThrough
                                   ? "See-through is on: clicks pass to what is behind the panel. Click here, or press \(keys.label(.clickThrough)), to turn it off."
                                   : "See-through: let clicks pass to what is behind the panel (\(keys.label(.clickThrough)))",
                               tint: app.clickThrough ? Theme.amber : nil) {
                        app.clickThrough.toggle()
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { app.clickThroughButtonFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, frame in
                                app.clickThroughButtonFrame = frame
                            }
                    })
                }
            }
            if codeLayout, !isPill {
                sidebarButton
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .background(DragHandle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: app.agentRunning)
    }

    /// Opens the sidebar of conversations. Hover: the conversations float
    /// open. Click: they are pinned beside the chat, which moves over to
    /// make room. Its symbol points to the side they open on.
    private var sidebarButton: some View {
        ToolbarGroup {
            IconButton(codeLayout ? "sidebar.right" : "sidebar.left",
                       help: app.sidebarPinned ? "Close the sidebar" : "Conversations. Hover to peek, click to keep open.",
                       tint: app.sidebarPinned ? Theme.accent : nil) {
                sidebarPeek = false
                app.refreshHistory()
                app.sidebarPinned.toggle()
                app.overlay?.setSidebar(app.sidebarPinned)
            }
            .onHover { inside in
                pointerOnSidebarButton = inside
                if inside {
                    guard !app.sidebarPinned, !sidebarPeek else { return }
                    app.refreshHistory()
                    sidebarPeek = true
                } else {
                    closePeekSoon()
                }
            }
        }
    }

    /// The agent at work: what it is doing, how far along it is, and a Stop
    /// button for as long as the task runs. When it wants to do something
    /// that needs a yes, each step slides in as its own card with Allow and
    /// Deny. A step that goes through flashes a checkmark; one that fails
    /// shakes the card.
    @ViewBuilder
    private var actionCard: some View {
        // What the agent is doing shows in the chat itself, under its
        // message: the checklist, the steps and the step in hand. The card
        // comes up here only when it needs the user, for a yes or an answer.
        if app.agentRunning, app.pendingApproval != nil || app.pendingQuestion != nil {
            AgentCard()
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let next = app.nextSteps {
            // Suggested next steps pop up here, like the agent's questions:
            // pick one to do it, or dismiss them.
            NextStepsCard(turnID: next.turn, steps: next.steps)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Everything optional in setup is done too.
    private var setupComplete: Bool {
        SetupGuide.essentialsDone && !settings.userDetails.isEmpty
    }

    // MARK: Chips

    private var chipRowNeeded: Bool {
        app.isListening
            || (settings.setupDismissed && !SetupGuide.essentialsDone)
            || (settings.separateMicVoices && !app.voiceEnrolled)
    }

    private var hasNotesContent: Bool {
        !app.segments.isEmpty || !app.conversation.turns.isEmpty || app.conversation.summary != nil
    }

    /// What kind of conversation this is: sets the reply style.
    private var modeMenu: some View {
        Menu {
            ForEach(SessionMode.allCases) { mode in
                Button {
                    settings.sessionMode = mode
                } label: {
                    Label(mode.label + (settings.sessionMode == mode ? "  ✓" : ""), systemImage: mode.icon)
                }
                .help(mode.summary)
            }
        } label: {
            Image(systemName: settings.sessionMode.icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mode: \(settings.sessionMode.label). \(settings.sessionMode.summary) Click to change.")
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                // Only while listening: when idle, the line under the title
                // already says so.
                if app.isListening {
                    liveChip
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                // Only things that need attention get a chip.
                if settings.setupDismissed, !SetupGuide.essentialsDone {
                    Button {
                        settings.setupDismissed = false
                    } label: {
                        Chip("Finish setup", icon: "exclamationmark.circle", tint: Theme.amber)
                    }
                    .buttonStyle(.plain)
                }
                if settings.separateMicVoices, !app.voiceEnrolled {
                    Chip("Voice not set up", icon: "person.crop.circle.badge.exclamationmark", tint: Theme.amber)
                }
            }
            // The chip row is a control bar: its chips sit on glass.
            .environment(\.glassChips, true)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 2)
        }
        .padding(.bottom, 6)
    }

    private var liveChip: some View {
        HStack(spacing: 5) {
            StatusDot(active: app.isListening)
            if app.isListening {
                LevelBars(level: max(app.micLevel, app.systemLevel), color: Theme.mint)
            }
        }
        .foregroundStyle(app.isListening ? Theme.mint : Theme.ink.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .liquidGlass(in: Capsule(), tint: Theme.mint)
        .fixedSize()
    }

    private var hairline: some View {
        LinearGradient(colors: [.clear, Theme.ink.opacity(0.14), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
    }

    /// The notes: a summary of the conversation so far. They update on their
    /// own as lines scroll out of the recent transcript, and on demand here.
    private func notesView(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(app.conversation.record == nil ? "Summary so far" : "Notes", systemImage: "note.text")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                if app.isSummarizing || app.isWritingUp {
                    LoadingMark(state: .thinking, size: 14)
                }
                Spacer(minLength: 4)
                IconButton("wand.and.stars",
                           help: "Write up the conversation so far: summary, topics, decisions, action items") {
                    app.writeUpRecord()
                }
                .disabled(app.isWritingUp)
                if !notes.isEmpty {
                    IconButton("doc.on.doc", help: "Copy the notes") {
                        app.copy(notes)
                    }
                }
                IconButton("square.and.arrow.down", help: "Save the notes and the transcript as a Markdown file") {
                    app.exportRecord()
                }
                IconButton("folder", help: "Open the folder of saved call wrap-ups") {
                    try? FileManager.default.createDirectory(at: app.wrapUpFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(app.wrapUpFolder)
                }
                IconButton("xmark", help: "Close the notes") {
                    showNotes = false
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = app.notesError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.amber)
                            .textSelection(.enabled)
                    }
                    if notes.isEmpty {
                        Text("No notes yet. Press the wand to write up the conversation so far. It is also written up on its own when you stop listening.")
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .foregroundStyle(Theme.ink.opacity(0.42))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownNotes(text: notes)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.ink.opacity(0.05)))
        .glassBorder(radius: Theme.cardRadius)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.amber.opacity(0.16)))
            Text(message)
                .font(.system(size: 11.5))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            IconButton("xmark", help: "Dismiss") {
                app.lastError = nil
            }
        }
        .foregroundStyle(Theme.amber)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.amber.opacity(0.09)))
        .glassBorder(radius: 11, tint: Theme.amber)
        .padding(.horizontal, Theme.gutter)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Input bar

    private var canSend: Bool {
        !app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        // What you type gets the full width on its own line; the model
        // choice and the buttons sit on the line below it.
        VStack(alignment: .leading, spacing: 6) {
            // What is being attached to this message, inside the chat box
            // above the text: a picture shows itself, anything else its
            // name. Once sent they move to Details.
            let pending = app.attachments.filter { app.pendingAttachments.contains($0.id) }
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pending) { file in
                            AttachmentThumb(file: file) {
                                app.removeAttachment(file.id)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            TextField(app.pendingQuestion != nil ? "Your answer" : (app.attachScreen ? "Ask about your screen" : "Ask anything"),
                      text: $app.draft,
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { app.sendDraft() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 3)
            HStack(alignment: .center, spacing: 8) {
            attachMenu
            // The model, the effort and the agent's mode take the form
            // that fits the room there is, fullest first, so nothing in
            // this row is ever pushed over anything else: names are
            // dropped before controls are.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modelMenu(compact: false)
                    EffortPill(isOpen: $showEffort)
                    AccessToggles()
                }
                HStack(spacing: 8) {
                    modelMenu(compact: false)
                    EffortPill(isOpen: $showEffort, compact: true)
                    AccessToggles()
                }
                HStack(spacing: 8) {
                    modelMenu(compact: false)
                    EffortPill(isOpen: $showEffort, compact: true)
                    AccessPill(compact: true)
                }
                HStack(spacing: 6) {
                    modelMenu(compact: true)
                    EffortPill(isOpen: $showEffort, compact: true)
                    AccessPill(compact: true)
                }
            }
            // Offered the row's room before the gap after it, or it
            // would be given half and choose a smaller form than it need.
            .layoutPriority(1)
            Spacer(minLength: 4)
            IconButton("text.viewfinder",
                       help: app.attachScreen
                           ? "Screen capture will be attached. Click to turn off."
                           : "Attach a screen capture to this message",
                       tint: app.attachScreen ? Theme.violet : nil) {
                app.attachScreen.toggle()
            }
            // Listening lives with the rest of the conversation controls.
            Button(action: { app.toggleListening() }) {
                Image(systemName: app.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: app.isListening ? 9 : 11, weight: .bold))
                    .foregroundStyle(app.isListening ? Theme.rose : Theme.ink.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(app.isListening
                                              ? Theme.rose.opacity(0.18)
                                              : Theme.ink.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Theme.rose.opacity(app.isListening ? 0.5 : 0), lineWidth: 1))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(app.isListening ? "Stop listening (\(keys.label(.listen)))" : "Listen to the conversation (\(keys.label(.listen)))")
            // The one place the agent is stopped from: while it works,
            // Stop stands where Send does. With something typed (an answer
            // to its question, a word of direction) Send is there as well.
            if app.agentRunning {
                Button(action: { app.stopAgent() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.rose))
                }
                .buttonStyle(.plain)
                .help("Stop the agent (\(keys.label(.stopAgent)))")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if !app.agentRunning || canSend {
                Button(action: { app.sendDraft() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(canSend ? 1 : 0.4))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canSend
                                                  ? AnyShapeStyle(Theme.accentGradient)
                                                  : AnyShapeStyle(Theme.ink.opacity(0.10))))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Return)")
            }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        // The chat box is the main control: it sits on glass, and its
        // edge lights up while you type.
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.shade.opacity(0.45)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.accent.opacity(inputFocused ? 0.55 : 0), lineWidth: 1)
            .allowsHitTesting(false))
        .animation(.easeOut(duration: 0.18), value: inputFocused)
        // The ask hotkey lands here: cursor in the box, ready to type.
        .onChange(of: app.focusInputRequest) { _, _ in
            inputFocused = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.attach([url]) }
                }
            }
            return true
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// Attached files, on a line just above the chat box. They scroll
    /// sideways when there are many.
    private var attachmentStrip: some View {
        ZStack(alignment: .trailing) {
            if !app.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(app.attachments) { file in
                            HStack(spacing: 4) {
                                Image(systemName: file.isFolder == true ? "folder.fill" : "doc.text.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(file.name)
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 150)
                                Button {
                                    app.removeAttachment(file.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .frame(width: 14, height: 14)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove from this conversation")
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 8)
                            .padding(.trailing, 4)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 0.75))
                            .fixedSize()
                        }
                    }
                    .padding(.leading, Theme.gutter)
                    .padding(.trailing, Theme.gutter)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: app.attachments.isEmpty ? 0 : 30)
        .padding(.top, app.attachments.isEmpty ? 0 : 6)
    }

    /// Switch engine and model without leaving the conversation.
    /// One "+" for everything that can be handed to Companion.
    private var attachMenu: some View {
        Menu {
            Button {
                app.pickAttachments(.files)
            } label: {
                Label("Files…", systemImage: "doc")
            }
            Button {
                app.pickAttachments(.images)
            } label: {
                Label("Images…", systemImage: "photo")
            }
            Button {
                app.pickAttachments(.folder)
            } label: {
                Label("Folder…", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(app.attachments.isEmpty ? Theme.ink.opacity(0.68) : Theme.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill((app.attachments.isEmpty ? Theme.ink : Theme.accent).opacity(0.10)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add files, images or a folder (or drop them here)")
    }

    private func modelMenu(compact: Bool) -> some View {
        ModelPill(isOpen: $showModels, compact: compact) { modelHover = $0 }
            .onChange(of: showModels) { _, open in
                // One card above the chat box at a time.
                if open { showEffort = false }
            }
            .onChange(of: showEffort) { _, open in
                if open { showModels = false }
            }
    }

    @ViewBuilder
    private func menuRow(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Chat thread

/// The conversation as one timeline: reply and screen turns in the order they
/// happened, each tagged with its kind. The filter chips narrow it to one kind.
struct ChatThread: View {
    @EnvironmentObject var app: AppState
    /// Room to leave at the top and bottom of the conversation for the
    /// bars that float over it.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// nil shows everything.
    @State private var filter: TurnKind?
    /// Older answers the user opened again.
    @State private var expanded: Set<UUID> = []
    /// Following the newest entry, or staying where the user scrolled to.
    @State private var followNewest = true
    /// How many of the newest entries are laid out.
    @State private var shownLimit = ChatThread.pageSize
    /// Last measured sizes, kept outside the view's state so measuring
    /// never causes a redraw by itself.
    @State private var scrollState = ThreadScrollState()

    static let pageSize = 120
    static let endID = "thread-end"

    private var allTurns: [ChatTurn] { app.conversation.turns }
    private var turns: [ChatTurn] {
        guard let filter else { return allTurns }
        return allTurns.filter { $0.kind == filter }
    }
    /// Everything in the order it happened: what was said, typed or captured
    /// (shown on the right) and what the assistant answered (on the left).
    /// With a filter on, only that kind of turn is shown.
    private var items: [TimelineItem] {
        guard filter == nil else { return turns.map(TimelineItem.turn) }
        let ordered = allTurns.enumerated()
            .sorted { a, b in
                let left = a.element.anchor ?? a.element.date
                let right = b.element.anchor ?? b.element.date
                return left == right ? a.offset < b.offset : left < right
            }
            .map(\.element)
        var result: [TimelineItem] = []
        var group: TranscriptGroup?
        var next = 0
        func closeGroup() {
            if let open = group {
                result.append(.speech(open))
                group = nil
            }
        }
        for segment in app.segments {
            while next < ordered.count, (ordered[next].anchor ?? ordered[next].date) < segment.timestamp {
                closeGroup()
                result.append(.turn(ordered[next]))
                next += 1
            }
            // Consecutive lines by the same speaker read as one paragraph.
            if var open = group,
               open.speaker == segment.speaker,
               open.tag == segment.tag,
               open.liveText.isEmpty,
               segment.timestamp.timeIntervalSince(open.lastTimestamp) < 20 {
                if segment.isFinal {
                    open.finalText += " " + segment.text
                    open.heardText += " " + (segment.original ?? segment.text)
                    open.polished = open.polished || Self.wasReworded(segment)
                    open.speakerCorrected = open.speakerCorrected || segment.speakerCorrected
                } else {
                    open.liveText = segment.text
                }
                open.lastTimestamp = segment.timestamp
                open.segmentIDs.append(segment.id)
                group = open
            } else {
                closeGroup()
                group = TranscriptGroup(id: segment.id,
                                        speaker: segment.speaker,
                                        tag: segment.tag,
                                        finalText: segment.isFinal ? segment.text : "",
                                        heardText: segment.isFinal ? (segment.original ?? segment.text) : "",
                                        liveText: segment.isFinal ? "" : segment.text,
                                        polished: Self.wasReworded(segment),
                                        speakerCorrected: segment.speakerCorrected,
                                        lastTimestamp: segment.timestamp,
                                        started: segment.timestamp,
                                        segmentIDs: [segment.id])
            }
        }
        closeGroup()
        result.append(contentsOf: ordered[next...].map(TimelineItem.turn))
        return result
    }

    /// True when a rewrite actually changed the line's wording.
    private static func wasReworded(_ segment: TranscriptSegment) -> Bool {
        guard let original = segment.original else { return false }
        return original != segment.text
    }

    private var lastReplyID: UUID? { allTurns.last { $0.kind == .reply }?.id }
    private var lastScreenID: UUID? { allTurns.last { $0.kind == .screen }?.id }
    private var busyTint: Color? {
        if app.isAnsweringScreen { return Theme.violet }
        if app.isReplying { return Theme.accent }
        return nil
    }

    static func tint(_ kind: TurnKind) -> Color {
        kind == .reply ? Theme.accent : Theme.violet
    }

    static func cursorID(_ kind: TurnKind) -> String {
        "cursor-\(kind.rawValue)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if items.isEmpty {
                Group {
                    if filter == nil {
                        emptyState
                    } else {
                        Text(emptyHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.36))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 34)
                    }
                }
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            } else {
                timeline
            }
            // The filters, and a note while an answer is written, float at
            // the top of the conversation under the app bar.
            if hasFilters || busyTint != nil {
                header
                    .environment(\.glassChips, true)
                    .padding(.top, topInset + 2)
            }
        }
        // The conversation sits directly on the panel: no card behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A fresh conversation: what Companion is ready for, and the three ways
    /// to start.
    private var emptyState: some View {
        VStack(spacing: 12) {
            OrbitMark(speed: app.isListening ? 1.0 : 0.3, dots: app.isListening ? 4 : 3, lines: 7,
                      trail: app.isListening, pulse: true)
                // Just the mark: no tile or border behind it.
                .frame(width: 56, height: 56)
            VStack(spacing: 4) {
                Text(app.isListening ? "Listening" : "Ready when you are")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                if app.isListening {
                    Text("What is said appears here, with each answer after it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
            }
            if !app.isListening {
                VStack(alignment: .leading, spacing: 8) {
                    startHint("mic.fill", "Listen", "and get replies as it goes")
                    startHint("keyboard", "Type", "a question or a task")
                    startHint("plus", "Attach", "files, images or a folder")
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.isListening)
    }

    private func startHint(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.08)))
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.88))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.45))
                .lineLimit(1)
        }
    }

    private var emptyHint: String {
        switch filter {
        case .none:
            return app.isListening
                ? "Listening. What is said appears here as it's spoken, with each answer right after what it answers."
                : "Press play to listen, or type below. The conversation and the answers appear here together, in order."
        case .some(.reply):
            return "No replies yet. They appear when the other side finishes speaking, or when you type."
        case .some(.screen):
            return "No screen answers yet. Use the capture button, or turn Screen on in the header."
        }
    }

    private var hasFilters: Bool { count(.reply) > 0 && count(.screen) > 0 }

    /// Top of the conversation: the filters, once there are both kinds to
    /// tell apart, and a note while an answer is being written.
    private var header: some View {
        HStack(spacing: 6) {
            if hasFilters {
                filterChip(nil, label: "All", count: allTurns.count, tint: nil)
                filterChip(.reply, label: "Reply", count: count(.reply), tint: Theme.accent)
                filterChip(.screen, label: "Screen", count: count(.screen), tint: Theme.violet)
            }
            if let busyTint {
                Chip("Writing", icon: "ellipsis", tint: busyTint)
            }
            Spacer(minLength: 4)
        }
    }

    private func count(_ kind: TurnKind) -> Int {
        allTurns.filter { $0.kind == kind }.count
    }

    private func filterChip(_ kind: TurnKind?, label: String, count: Int, tint: Color?) -> some View {
        let selected = filter == kind
        let color = tint ?? Theme.ink
        return Button {
            filter = kind
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? color : Theme.ink.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(selected ? 0.16 : 0.05)))
            .overlay(Capsule().strokeBorder(color.opacity(selected ? 0.38 : 0.10), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(kind == nil ? "Show everything" : "Show only \(label) turns")
    }

    /// The newest entries, as many as are being shown.
    private var shownItems: [TimelineItem] {
        Array(items.suffix(shownLimit))
    }

    /// Scrolling is handled here on purpose, with one rule: while you are at
    /// the bottom the view follows what is new; the moment you scroll up it
    /// stays exactly where you put it until you come back down.
    ///
    /// The rows are laid out in full (not lazily), so their heights are
    /// real and the view never jumps as it would with estimated heights.
    /// To keep that cheap, only the newest entries are laid out; older ones
    /// are a click away at the top.
    private var timeline: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                // No scroll bar: with the system set to always show them it
                // is a wide grey strip down the side of the conversation.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Room for the bar floating over the top (and the
                        // filters, when they show), so the first entry can
                        // be scrolled clear of them.
                        Color.clear
                            .frame(height: topInset + (hasFilters || busyTint != nil ? 30 : 0))
                        if items.count > shownLimit {
                            Button {
                                let anchor = shownItems.first?.id
                                shownLimit += Self.pageSize
                                // Stay on the entry you were looking at.
                                if let anchor {
                                    DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                Chip("Show \(min(items.count - shownLimit, Self.pageSize)) earlier", icon: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                        }
                    ForEach(shownItems) { item in
                        Group {
                        switch item {
                        case .speech(let group):
                            // What was heard: a compact line, not a card.
                            SpeechBubble(group: group)
                                .id(group.id)
                        case .turn(let turn):
                            // A quiet re-check of an answer shows no "thinking" effect.
                            let streaming = app.streamingTurns.contains(turn.id) && !app.quietTurns.contains(turn.id)
                            VStack(alignment: .leading, spacing: 3) {
                                if turn.origin == .typed || turn.kind == .screen {
                                    TurnInputBubble(turn: turn, streaming: streaming)
                                }
                                TurnView(turn: turn,
                                         tint: Self.tint(turn.kind),
                                         streaming: streaming,
                                         spokenWords: spokenWords(for: turn),
                                         cursorID: Self.cursorID(turn.kind),
                                         draft: app.draftTurns.contains(turn.id),
                                         // Every reply stays open in full; none is
                                         // folded away to a single line.
                                         collapsed: false,
                                         onToggle: nil)
                                    // Answers sit on the left and keep free room on
                                    // their right, so they don't span the full width.
                                    .padding(.top, 2)
                                    .padding(.trailing, 56)
                            }
                            .id(turn.id)
                        }
                        }
                    }
                        // Room for the chat box floating over the bottom. Its
                        // end is the end of the conversation, so "newest"
                        // always lands just above the chat box.
                        Color.clear
                            .frame(height: 1 + bottomInset)
                            .id(Self.endID)
                    }
                    .background(GeometryReader { inner in
                        Color.clear.preference(key: ThreadMetricsKey.self,
                                               value: ThreadMetrics(content: inner.size.height,
                                                                    bottom: inner.frame(in: .named("thread")).maxY,
                                                                    viewport: outer.size.height))
                    })
                }
                .coordinateSpace(name: "thread")
                .onPreferenceChange(ThreadMetricsKey.self) { metrics in
                    let grew = abs(metrics.content - scrollState.content) > 0.5
                        || abs(metrics.viewport - scrollState.viewport) > 0.5
                    scrollState.content = metrics.content
                    scrollState.viewport = metrics.viewport
                    if grew {
                        // New content, a growing answer or a resized panel:
                        // keep to the bottom only if that is where you were.
                        if followNewest {
                            proxy.scrollTo(Self.endID, anchor: .bottom)
                        }
                    } else {
                        // You scrolled. Near the bottom means "follow".
                        let atBottom = metrics.bottom - metrics.viewport < 40
                        if atBottom != followNewest { followNewest = atBottom }
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(Self.endID, anchor: .bottom) }
                }
                .onChange(of: app.conversation.id) { _, _ in
                    // Another conversation opens at its newest entry.
                    shownLimit = Self.pageSize
                    followNewest = true
                    DispatchQueue.main.async { proxy.scrollTo(Self.endID, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followNewest {
                        Button {
                            followNewest = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.endID, anchor: .bottom)
                            }
                        } label: {
                            Chip("Newest", icon: "arrow.down", tint: Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .environment(\.glassChips, true)
                        .padding(.bottom, 6 + bottomInset)
                        .transition(.opacity)
                        .help("Jump to the newest entry and follow it")
                    }
                }
                .animation(.easeOut(duration: 0.15), value: followNewest)
            }
        }
    }

    /// Read-along applies to the newest answer of each kind.
    /// How much of an answer to show as already said. Always none: while a
    /// reply is being used its text stays exactly as written, with nothing
    /// dimmed, moved or scrolled. Use is shown by the badge alone.
    private func spokenWords(for turn: ChatTurn) -> Int {
        0
    }
}

/// What to do next after the agent finishes, offered above the chat box in
/// the same form as its questions: numbered choices, one click to do one.
struct NextStepsCard: View {
    @EnvironmentObject var app: AppState
    let turnID: UUID
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16, height: 16)
                Text("Next step")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 6)
                IconButton("xmark", help: "Dismiss these suggestions") {
                    app.dismissSuggestions(turnID)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Button {
                        app.dismissSuggestions(turnID)
                        app.send(step)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accent.opacity(0.16)))
                            Text(step)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink.opacity(0.92))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.06)))
                        .glassBorder(radius: 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Do this next")
                }
            }
            Text("Or type what you want instead.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.48))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.shade.opacity(0.28)))
        .glassBorder(radius: Theme.cardRadius, tint: Theme.accent)
    }
}

/// An attachment shown in the chat box while a message is being written: a
/// picture as itself, anything else as a small card with its name. The
/// cross takes it off again.
struct AttachmentThumb: View {
    let file: Attachment
    let remove: () -> Void
    @State private var hover = false

    private static let pictures: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"]

    private var picture: NSImage? {
        guard let path = file.path, Self.pictures.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: file.isFolder == true ? "folder.fill" : "doc.text.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    Text(file.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.88))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                .padding(7)
                .frame(width: 96, height: 64, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.08)))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove this attachment")
                .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .help(file.path ?? file.name)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A small ring that fills as the conversation takes up more of the engine's
/// context window, with the share beside it. Hover for where it goes.
struct ContextMeter: View {
    let use: ContextUse
    let window: Int
    /// What this chat's requests have cost so far.
    var spent = 0.0

    private var share: Double {
        window > 0 ? min(Double(use.total) / Double(window), 1) : 0
    }

    private var color: Color {
        share < 0.5 ? Theme.mint : (share < 0.85 ? Theme.amber : Theme.rose)
    }

    private var detail: String {
        let percent = share < 0.01 && use.total > 0 ? "under 1%" : "\(Int((share * 100).rounded()))%"
        var lines = [
            "This chat holds about \(ContextUse.short(use.total)) tokens, \(percent) of this engine's \(ContextUse.short(window)) window.",
            "",
            "Heard: \(ContextUse.short(use.transcript))",
            "Answers and what you typed: \(ContextUse.short(use.answers))",
            "Attached files: \(ContextUse.short(use.attachments))",
            "Notes: \(ContextUse.short(use.notes))",
            "",
            "Spent on this chat so far: \(Money.text(spent)). Details in Settings > Usage."
        ]
        if share >= 0.85 {
            lines += ["", "It is more than fits in one request: older parts are summarised and the relevant passages are picked out, so it still works."]
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Theme.ink.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(share, use.total > 0 ? 0.03 : 0))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(ContextUse.short(use.total))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.5))
        }
        .fixedSize()
        .help(detail)
        .animation(.easeOut(duration: 0.3), value: share)
    }
}

/// The things you do to the conversation: recheck it, clean it up, draft a
/// reply now, answer from the screen now. Sits at the right of the line
/// just above the chat box.
struct ThreadActions: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 6) {
            if app.isRescanning {
                LoadingMark(state: .working, size: 16)
                    .frame(width: 18, height: 18)
                Text("Rechecking \(app.rescanProgress)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .fixedSize()
            }
            ToolbarGroup {
                if app.isRescanning {
                    IconButton("stop.fill", help: "Stop the recheck here. Fixes already made stay.") {
                        app.stopRescan()
                    }
                } else {
                    if app.canUndoRescan {
                        IconButton("arrow.uturn.backward", help: "Undo the recheck") {
                            app.undoRescan()
                        }
                    }
                    IconButton("arrow.triangle.2.circlepath",
                               help: "Recheck, newest first: fix who said what, rewrite each line clearly, then verify the replies still match") {
                        app.rescanTranscript()
                    }
                }
                if app.unusedReplyCount > 0 {
                    IconButton("eraser", help: "Clean up: remove the \(app.unusedReplyCount) suggested replies you did not say or that match nothing") {
                        app.cleanUnusedReplies()
                    }
                }
                IconButton("bolt.fill", help: "Draft a reply now (\(Shortcuts.shared.label(.reply)))", tint: Theme.accent) {
                    app.suggestNow()
                }
                IconButton("camera.viewfinder", help: "Capture the screen and answer now (\(Shortcuts.shared.label(.screen)))", tint: Theme.violet) {
                    app.answerScreenNow()
                }
            }
        }
    }
}

/// What the conversation's scroll view measures on each layout.
struct ThreadMetrics: Equatable {
    var content: CGFloat = 0
    var bottom: CGFloat = 0
    var viewport: CGFloat = 0
}

struct ThreadMetricsKey: PreferenceKey {
    static var defaultValue = ThreadMetrics()
    static func reduce(value: inout ThreadMetrics, nextValue: () -> ThreadMetrics) {
        value = nextValue()
    }
}

final class ThreadScrollState {
    var content: CGFloat = 0
    var viewport: CGFloat = 0
}

/// One exchange: the prompt (heard, typed or captured), the screenshot when
/// there is one, and the answer with its actions.
struct TurnView: View {
    @EnvironmentObject var app: AppState
    let turn: ChatTurn
    let tint: Color
    let streaming: Bool
    let spokenWords: Int
    let cursorID: String
    /// The question may still be unfinished, so the answer is not confirmed yet.
    var draft = false
    /// Folded to one line: an older answer, out of the way until clicked.
    var collapsed = false
    /// Folds or unfolds the answer. nil for the current answer, which stays open.
    var onToggle: (() -> Void)?
    @State private var hover = false
    @State private var copied = false

    /// The engine, and which of the user's material the answer drew on.
    private var footnote: String {
        guard let sources = turn.sources, !sources.isEmpty else { return turn.model }
        let names = sources.prefix(3).joined(separator: ", ") + (sources.count > 3 ? " +\(sources.count - 3)" : "")
        return "\(turn.model)  ·  from \(names)"
    }

    /// The engine that answered, for its logo.
    private var engine: (kind: LLMProviderKind, tool: String?)? {
        EngineLogo.mark(of: turn.model)
    }

    /// The model alone, where the logo already says which engine.
    private var modelName: String {
        guard engine != nil else { return turn.model }
        return turn.model.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }

    /// What kind of work the answer was: what the agent mostly did to get
    /// to it, or else where the question came from.
    private var work: (icon: String, help: String) {
        if let steps = turn.steps, !steps.isEmpty {
            let kinds = Set(steps.map(\.kind))
            if kinds.contains(.edit) { return ("pencil", "Edited files") }
            if kinds.contains(.run) { return ("terminal", "Ran commands") }
            if !kinds.isDisjoint(with: [.open, .click, .type, .key]) { return ("macwindow", "Worked in other apps") }
            if kinds.contains(.web) { return ("globe", "Looked on the web") }
            if kinds.contains(.read) || kinds.contains(.search) { return ("doc.text.magnifyingglass", "Read files") }
        }
        if turn.kind == .screen {
            return (turn.origin == .auto ? "eye.fill" : "text.viewfinder", "Answer from the screen")
        }
        switch turn.origin {
        case .typed: return ("bubble.left.fill", "Answer to what you wrote")
        case .auto: return ("waveform", "Reply to what was said")
        case .manual: return ("sparkles", "Reply drafted when asked for")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A folded older answer is one line: its facts, then its start.
            if collapsed {
                HStack(alignment: .center, spacing: 6) {
                    facts
                    Text(turn.answer.isEmpty ? (turn.error ?? "") : MarkdownNotes.plain(turn.answer))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(hover ? 0.7 : 0.35))
                }
            }

            if !collapsed {
                if let error = turn.error {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amber)
                        .textSelection(.enabled)
                }

                // The work behind the answer, folded to one line: what was
                // run, opened or clicked. It fills in live while the agent
                // is working and stays with the answer afterwards.
                // The agent's checklist for a longer task, ticked off as it goes.
                if let plan = turn.plan, !plan.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(plan.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: item.state == .done ? "checkmark.circle.fill"
                                      : (item.state == .doing ? "circle.dotted.circle" : "circle"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(item.state == .done ? Theme.mint
                                                     : (item.state == .doing ? tint : Theme.ink.opacity(0.35)))
                                Text(item.text)
                                    .font(.system(size: 11.5, weight: item.state == .doing ? .semibold : .regular))
                                    .foregroundStyle(Theme.ink.opacity(item.state == .done ? 0.5 : 0.88))
                                    .strikethrough(item.state == .done, color: Theme.ink.opacity(0.3))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let steps = turn.steps, !steps.isEmpty {
                    WorkTrail(steps: steps, working: streaming && turn.answer.isEmpty, tint: tint)
                }

                if turn.answer.isEmpty {
                    if streaming {
                        // The mark turns slowly while the model has not
                        // answered, quickly while the agent is at work.
                        HStack(spacing: 7) {
                            LoadingMark(state: turn.steps == nil ? .thinking : .working, size: 18)
                            Text(turn.steps == nil ? "Thinking…" : (app.agentStatus ?? "Working…"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink.opacity(0.4))
                        }
                    }
                } else {
                    // An answer that came back formatted (lists, tables, bold) is
                    // always shown formatted, never as raw Markdown.
                    // New text fades in as it streams instead of popping.
                    Group {
                        if MarkdownNotes.looksFormatted(turn.answer) {
                            MarkdownNotes(text: turn.answer, size: 13)
                        } else {
                            ReadAlongText(text: turn.answer, spokenWords: spokenWords, tint: tint, cursorID: cursorID)
                        }
                    }
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.22), value: turn.answer)
                }

                // The answer is just its words. Under it a thin line is
                // kept free, the same as under what was said on the right:
                // when, which model, and the answer's tools show there
                // while the pointer is on it, so nothing moves.
                HStack(alignment: .center, spacing: 8) {
                    facts
                    Text(modelName)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(footnote)
                    if !streaming {
                        actions
                        if let onToggle {
                            tool("chevron.up", help: "Fold this answer", action: onToggle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 16)
                // A draft keeps its mark in view; the rest waits for the pointer.
                .opacity(hover || draft ? 1 : 0)
                .allowsHitTesting(hover)
                .animation(.easeOut(duration: 0.14), value: hover)
            }
        }
        .padding(.leading, collapsed ? 10 : 2)
        .padding(.trailing, collapsed ? 10 : 2)
        .padding(.vertical, collapsed ? 5 : 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { onToggle?() }
        }
        .help(collapsed ? "Click to open this answer" : "")
        // An answer is plain text on the page, the way a document reads:
        // what was said sits in bubbles on the right, and the reply needs
        // no box of its own. Only a folded older answer keeps a light
        // outline, so it reads as something that can be opened.
        .background {
            if collapsed {
                BubbleShape(side: .left).fill(Theme.isLight ? Theme.card.opacity(hover ? 1 : 0.8)
                                              : Theme.ink.opacity(hover ? 0.08 : 0.05))
            }
        }
        .overlay {
            if collapsed {
                BubbleShape(side: .left).strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5)
            }
        }
        .onHover { hover = $0 }
        // Right-click anywhere on the answer copies all of it.
        .contextMenu {
            if !turn.answer.isEmpty {
                Button("Copy") { app.copy(turn.answer) }
            }
        }
    }

    /// What kind of answer it is, its state, and when.
    @ViewBuilder
    private var facts: some View {
        // Which engine answered, by its own logo, then what the work was.
        if let engine {
            EngineLogo(kind: engine.kind, tool: engine.tool, size: 10)
                .foregroundStyle(tint)
                .help(turn.model)
        }
        Image(systemName: work.icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(engine == nil ? tint : Theme.ink.opacity(0.55))
            .help(work.help)
        if draft {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.amber)
                .symbolEffect(.variableColor.iterative, isActive: true)
                .help("Draft: the question may not be finished. This answer is confirmed once it is.")
        }
        if let usage = app.usage(of: turn) {
            usageBadge(usage)
        }
        if let matched = turn.matched {
            matchBadge(matched)
        }
        TimeLabel(date: turn.anchor ?? turn.date)
    }

    /// A small tool on the line under an answer, the size of the ones
    /// under what was said.
    private func tool(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint ?? Theme.ink.opacity(0.55))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// What the recheck found: does this reply answer something that was
    /// really asked in the conversation?
    private func matchBadge(_ matched: Bool) -> some View {
        let color = matched ? Theme.mint : Theme.rose
        return Image(systemName: matched ? "checkmark.seal.fill" : "xmark.seal.fill")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .help(matched
              ? "Rechecked: this reply answers something that was asked in the conversation."
              : "Rechecked: nothing in the conversation matches this reply. Clean up removes it.")
    }

    /// Whether this suggestion was actually said in the conversation.
    private func usageBadge(_ usage: TurnUsage) -> some View {
        let label: String
        let icon: String
        let color: Color
        let help: String
        switch usage {
        case .used:
            label = "Used"
            icon = "checkmark.circle.fill"
            color = Theme.mint
            help = "Used: you said this reply."
        case .partly:
            label = "Partly used"
            icon = "circle.lefthalf.filled"
            color = Theme.amber
            help = "Partly used: you said part of this reply."
        case .unused:
            label = "Not used"
            icon = "minus.circle"
            color = Theme.ink.opacity(0.5)
            help = "Not used: you did not say this reply. Clean up removes replies like this."
        }
        return Image(systemName: icon)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .accessibilityLabel(label)
            .help(help)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if !turn.answer.isEmpty {
                tool(copied ? "checkmark" : "doc.on.doc", help: "Copy", tint: copied ? Theme.mint : nil) {
                    app.copy(turn.answer)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
            }
            tool("arrow.clockwise", help: "Regenerate") { app.regenerate(turn.id) }
            tool("arrow.uturn.left", help: "Reuse this prompt in the input") { app.reuse(turn.id) }
            tool("trash", help: "Delete this turn") { app.deleteTurn(turn.id) }
        }
    }
}

/// The work an answer took, shown the way an assistant shows its working:
/// one line that says what was done ("Ran 2 commands and opened 1 app"),
/// which opens into the steps; a command opens further into its output.
struct WorkTrail: View {
    let steps: [WorkStep]
    /// Still going: the line shows the latest step.
    let working: Bool
    let tint: Color
    @State private var open = false
    @State private var shown: Set<Int> = []

    private func icon(_ kind: WorkStep.Kind) -> String {
        switch kind {
        case .run: return "terminal"
        case .open: return "macwindow"
        case .click: return "cursorarrow.click"
        case .type: return "keyboard"
        case .key: return "command"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .edit: return "pencil"
        case .web: return "globe"
        case .other: return "circle"
        }
    }

    private var failures: Int { steps.filter(\.failed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one-line summary. Click to see the steps.
            HStack(spacing: 6) {
                if working {
                    LoadingMark(state: .working, size: 12)
                }
                Text(working ? (steps.last?.title ?? "Working") : WorkStep.summary(of: steps))
                    .font(.system(size: 11.5, design: working && steps.last?.kind == .run ? .monospaced : .default))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if failures > 0, !working {
                    Text("\(failures) failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { open.toggle() }
            }
            .help(open ? "Hide the steps" : "Show the steps")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.ink.opacity(0.07))
                                .frame(height: 1)
                        }
                        row(index, step)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
                .padding(.top, 3)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ step: WorkStep) -> some View {
        let hasOutput = step.output != nil
        let expanded = shown.contains(index)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: step.failed ? "exclamationmark.triangle.fill" : icon(step.kind))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(step.failed ? Theme.amber : Theme.ink.opacity(0.5))
                    .frame(width: 14)
                Text(step.title)
                    .font(.system(size: 11, design: step.kind == .run ? .monospaced : .default))
                    .foregroundStyle(Theme.ink.opacity(0.82))
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if hasOutput {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            if expanded, let output = step.output {
                ScrollView(.vertical) {
                    Text(output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.shade.opacity(0.45)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasOutput else { return }
            if expanded {
                shown.remove(index)
            } else {
                shown.insert(index)
            }
        }
        .help(hasOutput ? (expanded ? "Hide the output" : "Show the output") : "")
    }
}

/// Small clock time shown on every entry in the conversation.
struct TimeLabel: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.hour().minute())
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.ink.opacity(0.38))
            .fixedSize()
    }
}

/// Chat bubble outline: rounded, with a tighter corner on the side it
/// belongs to (left for the assistant, right for inputs).
struct BubbleShape: InsettableShape {
    enum Side { case left, right }
    let side: Side
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let round = Theme.bubbleRadius
        let radii = RectangleCornerRadii(topLeading: round,
                                         bottomLeading: side == .left ? 4 : round,
                                         bottomTrailing: side == .right ? 4 : round,
                                         topTrailing: round)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        BubbleShape(side: side, inset: inset + amount)
    }
}

/// One entry in the conversation timeline.
enum TimelineItem: Identifiable {
    case speech(TranscriptGroup)
    case turn(ChatTurn)

    var id: UUID {
        switch self {
        case .speech(let group): return group.id
        case .turn(let turn): return turn.id
        }
    }
}

/// A paragraph of what was heard, from the user or from the other people:
/// a compact line in the flow of the conversation.
struct SpeechBubble: View {
    let group: TranscriptGroup

    var body: some View {
        // What was heard sits on the right, as wide as its words; replies
        // sit on the left. Which side says who it came from.
        SegmentRow(group: group)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
    }
}

/// What the user typed, or the screen that was captured.
struct TurnInputBubble: View {
    @EnvironmentObject var app: AppState
    let turn: ChatTurn
    let streaming: Bool

    private var tint: Color { ChatThread.tint(turn.kind) }
    @State private var hover = false
    /// Asked whether to go back to before this message, and what that
    /// would undo.
    @State private var restoring: (files: Int, turns: Int)?

    /// The line above a message that goes back to the checkpoint before
    /// it. It shows while the pointer is on the message, and only where
    /// files have been changed since.
    @ViewBuilder
    private var checkpointLine: some View {
        HStack(spacing: 6) {
            if let restoring {
                Text("Put \(restoring.files) file\(restoring.files == 1 ? "" : "s") back and remove \(restoring.turns) message\(restoring.turns == 1 ? "" : "s") from here?")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
                checkpointChoice("Restore", tint: Theme.amber) {
                    self.restoring = nil
                    app.restoreCheckpoint(before: turn.id)
                }
                checkpointChoice("Cancel", tint: Theme.ink.opacity(0.7)) { self.restoring = nil }
            } else {
                Button {
                    restoring = app.checkpoint(before: turn.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Restore checkpoint")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go back to just before this message: files changed since are put back, and this message and everything after it leave the chat. Its words return to the chat box.")
            }
        }
        .frame(height: 16)
        .padding(.trailing, 4)
        .opacity(hover || restoring != nil ? 1 : 0)
        .allowsHitTesting(hover || restoring != nil)
    }

    private func checkpointChoice(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(Capsule().fill(tint.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
        if !streaming, app.hasCheckpoint(turn) {
            checkpointLine
        }
        VStack(alignment: .leading, spacing: 3) {
            // One line: what you typed, with its mark and time. A screen
            // capture adds its thumbnail above.
            if turn.kind == .screen {
                if let file = turn.imageFile {
                    TurnThumbnail(url: app.store.imageURL(conversation: app.conversation.id, file: file),
                                  processing: streaming && turn.answer.isEmpty)
                } else if streaming && turn.context == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "text.viewfinder")
                        Text("Capturing screen…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.05)))
                }
            }
            // What was attached with this message.
            if let attached = turn.attached, !attached.isEmpty {
                ForEach(attached, id: \.self) { name in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .semibold))
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.08)))
                }
            }
            if !turn.prompt.isEmpty {
                Text(turn.prompt)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(Theme.ink.opacity(0.93))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if turn.kind == .screen, turn.imageFile == nil, !streaming {
                // A capture with no picture kept and no question: say what it was.
                Text("Screen capture")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: turn.kind == .screen ? 260 : nil, alignment: .leading)
        .background(BubbleShape(side: .right).fill(tint.opacity(hover ? 0.15 : 0.10)))
        .overlay(BubbleShape(side: .right).strokeBorder(tint.opacity(hover ? 0.38 : 0.24), lineWidth: 0.5))
            // The same free line under it as under what was heard.
            HStack(spacing: 8) {
                TimeLabel(date: turn.date)
                Image(systemName: turn.kind == .screen ? "text.viewfinder" : "keyboard")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                    .help(turn.kind == .screen ? "Screen capture" : "You typed this")
                if !turn.prompt.isEmpty {
                    Button {
                        app.copy(turn.prompt)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .frame(height: 16)
            .padding(.trailing, 4)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
        // Right-click anywhere on the bubble copies all of it.
        .contextMenu {
            if !turn.prompt.isEmpty {
                Button("Copy") { app.copy(turn.prompt) }
            }
        }
        // Your own input is on the right, like what was heard.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
    }
}

/// The screenshot a Screen turn is working from. Click to open it.
struct TurnThumbnail: View {
    let url: URL
    let processing: Bool
    @State private var image: NSImage?

    var body: some View {
        Theme.ink.opacity(0.05)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .overlay(alignment: .top) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if processing {
                    Chip("Reading", icon: "eye.fill", tint: Theme.violet)
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
            .help("Open capture")
            .task(id: url) {
                image = NSImage(contentsOf: url)
            }
    }
}

/// Answer text that dims what the user has already spoken aloud and exposes
/// a scroll anchor at the point they have reached.
struct ReadAlongText: View {
    let text: String
    let spokenWords: Int
    let tint: Color
    let cursorID: String

    var body: some View {
        if let cut = splitIndex(afterWords: spokenWords), cut > text.startIndex {
            Text(String(text[..<cut]))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(tint.opacity(0.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(text[cut...]).trimmingCharacters(in: .whitespaces))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink.opacity(0.96))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(cursorID)
        } else {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink.opacity(0.96))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Index right after the Nth word of `text`, counting words the same way
    /// the voice matcher does (runs of letters and digits).
    private func splitIndex(afterWords n: Int) -> String.Index? {
        guard n > 0 else { return nil }
        var count = 0
        var inWord = false
        for index in text.indices {
            let character = text[index]
            let isWordChar = character.isLetter || character.isNumber
            if isWordChar {
                inWord = true
            } else if inWord {
                inWord = false
                count += 1
                if count == n { return index }
            }
        }
        if inWord {
            count += 1
        }
        return count >= n ? text.endIndex : nil
    }
}

// MARK: - Notes

/// Renders Markdown the way models write it: headings, bullets, checkboxes,
/// numbered lists, tables and inline bold or code. Used for the notes and
/// for answers that come back formatted.
struct MarkdownNotes: View {
    let text: String
    var size: CGFloat = 12.5

    private enum Block {
        case line(String)
        case table([[String]])
        /// A fenced block: commands, output, source code.
        case code(String)
    }

    /// The text on one line with the Markdown symbols taken out, for previews.
    static func plain(_ text: String) -> String {
        var result = text
        for symbol in ["**", "__", "`", "#", "|", "- [ ] ", "- [x] "] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        return result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !$0.allSatisfy { "-:".contains($0) } }
            .joined(separator: " ")
    }

    /// Whether a text uses Markdown structure worth rendering.
    static func looksFormatted(_ text: String) -> Bool {
        if text.contains("**") || text.contains("__") || text.contains("`") || text.contains("```")
            || text.contains("\n|") || text.hasPrefix("|") { return true }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return true
            }
        }
        return false
    }

    private var blocks: [(offset: Int, block: Block)] {
        var result: [Block] = []
        var rows: [[String]] = []
        func closeTable() {
            if !rows.isEmpty {
                result.append(.table(rows))
                rows = []
            }
        }
        var code: [String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Between ``` fences every line is kept exactly as written.
            if line.hasPrefix("```") {
                closeTable()
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                let cells = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| rule under the header carries no content.
                let isRule = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
                }
                if !isRule {
                    rows.append(cells)
                }
                continue
            }
            closeTable()
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue }
            // Lines that follow one another are kept as one piece of text,
            // so a selection can run across lines and paragraphs.
            if case .line(let before)? = result.last {
                result[result.count - 1] = .line(before + "\n" + line)
            } else {
                result.append(.line(line))
            }
        }
        closeTable()
        // A fence still open (the answer is arriving) shows what it has.
        if let lines = code, !lines.isEmpty {
            result.append(.code(lines.joined(separator: "\n")))
        }
        return result.enumerated().map { (offset: $0.offset, block: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks, id: \.offset) { item in
                switch item.block {
                case .line(let line):
                    row(line)
                case .table(let rows):
                    table(rows)
                case .code(let source):
                    Text(source)
                        .font(.system(size: size - 1.5, design: .monospaced))
                        .lineSpacing(1.5)
                        .foregroundStyle(Theme.ink.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.shade.opacity(0.32)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
                        .padding(.vertical, 2)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < cells.count ? cells[column] : ""))
                            .font(.system(size: size - 0.5, weight: index == 0 ? .semibold : .regular))
                            .lineSpacing(1.5)
                            .foregroundStyle(Theme.ink.opacity(index == 0 ? 0.95 : 0.88))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if index == 0, rows.count > 1 {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.14))
                        .frame(height: 0.5)
                        .gridCellColumns(max(columns, 1))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
        .padding(.vertical, 2)
    }

    /// Lines that follow one another, drawn as a single piece of text: a
    /// selection cannot leave the `Text` it started in, so headings, bullets
    /// and paragraphs are joined into one instead of one view per line.
    private func row(_ lines: String) -> some View {
        var whole = Text("")
        for (index, line) in lines.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                whole = whole + Text("\n")
                // A smaller heading, or a line that is all bold, is a
                // section title: give it air.
                if line.hasPrefix("##") || (line.hasPrefix("**") && line.hasSuffix("**")) {
                    whole = whole + Text(" \n").font(.system(size: 4))
                }
            }
            whole = whole + piece(line)
        }
        return whole
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line of Markdown as styled text: a heading, a bullet or a plain line.
    private func piece(_ line: String) -> Text {
        if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            if level == 1 {
                return Text(inline(title))
                    .font(.system(size: size + 1.5, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.95))
            }
            return Text(inline(title))
                .font(.system(size: size - 1.5, weight: .bold, design: .rounded))
                .foregroundColor(Theme.accent)
        }
        if let item = bullet(line) {
            let mark = item.symbol == "circle.fill"
                ? Text(" •  ")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.5))
                : (Text(Image(systemName: item.symbol)) + Text("  "))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.mint)
            return mark + Text(inline(item.text))
                .font(.system(size: size))
                .foregroundColor(Theme.ink.opacity(0.9))
        }
        return Text(inline(line))
            .font(.system(size: size))
            .foregroundColor(Theme.ink.opacity(0.9))
    }

    private func bullet(_ line: String) -> (symbol: String, text: String)? {
        for (prefix, symbol) in [("- [ ] ", "square"), ("- [x] ", "checkmark.square"),
                                 ("- ", "circle.fill"), ("* ", "circle.fill"), ("• ", "circle.fill")] {
            if line.hasPrefix(prefix) {
                return (symbol, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// Bold, italics and code inside a line.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Transcript row

/// One speaker's run of speech: the settled text plus what is still being spoken.
struct TranscriptGroup: Identifiable {
    let id: UUID
    let speaker: Speaker
    let tag: String?
    var finalText: String
    /// The same speech as it was originally heard, before polishing.
    var heardText: String
    var liveText: String
    /// Whether polishing changed any wording in this group.
    var polished: Bool
    /// Whether the speaker label was corrected from context.
    var speakerCorrected: Bool
    var lastTimestamp: Date
    /// When this paragraph started.
    var started: Date
    /// The transcript lines merged into this paragraph.
    var segmentIDs: [UUID]
}

struct SegmentRow: View {
    @EnvironmentObject var app: AppState
    /// Watched so the bubbles follow the look as it is changed.
    @ObservedObject private var appearance = AppSettings.shared
    let group: TranscriptGroup
    @State private var showHeard = false
    @State private var showDetails = false

    private var isMe: Bool { group.speaker == .me }
    /// Mic speech whose speaker isn't identified yet.
    private var isPending: Bool { group.tag == TranscriptSegment.pendingTag }

    private var text: Text {
        let settled = Text(showHeard && group.polished ? group.heardText : group.finalText)
            .foregroundColor(Theme.ink.opacity(0.93))
        guard !group.liveText.isEmpty else { return settled }
        let live = Text(group.finalText.isEmpty ? group.liveText : " " + group.liveText)
            .italic()
            .foregroundColor(Theme.ink.opacity(0.55))
        return settled + live
    }

    /// The bubble's color says who spoke: purple for you, each other
    /// person their own.
    private var speakerTint: Color {
        isPending ? Theme.ink.opacity(0.6) : Theme.speakerColor(isMe: isMe, tag: group.tag)
    }

    var body: some View {
        // The bubble holds just the words. Under it, on the right, a thin
        // line is kept free; who said it, when, and the line's tools show
        // there while the pointer is on the bubble, so nothing moves.
        VStack(alignment: .trailing, spacing: 2) {
            text
                .font(.system(size: 12.5))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(BubbleShape(side: .right).fill(speakerTint.opacity(beingRechecked ? 0.26 : (showDetails ? 0.16 : 0.11))))
                .background(BubbleShape(side: .right).fill(Theme.bubbleShade))
                .overlay(BubbleShape(side: .right).strokeBorder(speakerTint.opacity(showDetails ? 0.36 : 0.20), lineWidth: 0.5))
            details
                .frame(height: 16)
                .padding(.trailing, 4)
                .opacity(showDetails ? 1 : 0)
                .allowsHitTesting(showDetails)
        }
        .contentShape(Rectangle())
        .onHover { showDetails = $0 }
        .animation(.easeOut(duration: 0.14), value: showDetails)
        .animation(.easeInOut(duration: 0.2), value: beingRechecked)
        // Right-click anywhere on the bubble copies the whole line.
        .contextMenu {
            if !group.finalText.isEmpty {
                Button("Copy") { app.copy(group.finalText) }
            }
        }
    }

    /// Who said it (click to fix), when, and the line's tools.
    private var details: some View {
        HStack(spacing: 8) {
            TimeLabel(date: group.started)
            // Wrong person? Clicking the name hands the line to the next speaker.
            Button {
                app.cycleSpeaker(of: group.segmentIDs)
            } label: {
                Text(isPending ? "···" : (isMe ? "You" : (group.tag ?? "Them")))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(speakerTint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPending || group.finalText.isEmpty)
            .help("Wrong speaker? Click to switch who said this.")
            if group.speakerCorrected {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.amber.opacity(0.85))
                    .help("Speaker corrected. The automatic label was different.")
            }
            if group.polished {
                // Polished line: the wand flips to what was originally heard.
                Button {
                    showHeard.toggle()
                } label: {
                    Image(systemName: showHeard ? "ear" : "wand.and.stars")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(showHeard ? Theme.amber : Theme.accent.opacity(0.85))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showHeard
                      ? "Showing what was heard. Click for the polished version."
                      : "Polished. Click to see what was originally heard.")
            }
            Button {
                app.copy(group.finalText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
    }

    private var beingRechecked: Bool {
        guard let id = app.rescanningID else { return false }
        return group.segmentIDs.contains(id)
    }
}
