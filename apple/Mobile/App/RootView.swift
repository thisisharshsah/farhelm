import CompanionDesign
import CompanionKit
import SwiftUI

/// Pairing until a Mac is paired. Then, as on the Mac: on a wide screen
/// (iPad) the chats beside the chat; on iPhone the chat, with the chats
/// sliding in from the left over it.
struct RootView: View {
    @Environment(MacStore.self) private var store
    @State private var sidebarOpen = false
    /// The chats' width beside the chat on a wide screen, set by dragging
    /// the gap between them.
    @AppStorage("chatsWidth") private var chatsWidth = 300.0

    var body: some View {
        Group {
            if store.macs.isEmpty {
                NavigationStack { PairView() }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 700 {
                        // As on the Mac: the chats and the chat are panels
                        // of their own, a gap apart, and the gap resizes them.
                        HStack(spacing: 0) {
                            SidebarView()
                                .frame(maxHeight: .infinity)
                                .panelCard()
                                .frame(width: chatsWidth)
                            PanelGap(width: $chatsWidth)
                            ChatView(showChats: nil, framed: true)
                                .panelCard()
                        }
                        .padding(Design.panelGap)
                        .background(CompanionBackdrop())
                    } else {
                        ZStack(alignment: .leading) {
                            ChatView(showChats: { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { sidebarOpen = true } })
                            if sidebarOpen {
                                // The scrim under the chats: the look's own shade.
                                Design.palette().shade.opacity(0.35)
                                    .ignoresSafeArea()
                                    .onTapGesture { close() }
                                    .transition(.opacity)
                                SidebarView(picked: close)
                                    .frame(width: min(geometry.size.width * 0.84, 340))
                                    .frame(maxHeight: .infinity)
                                    .glassPanel()
                                    .padding(.leading, Design.Space.xs)
                                    .padding(.vertical, Design.Space.xxs)
                                    .transition(.move(edge: .leading))
                                    .gesture(DragGesture().onEnded { drag in
                                        if drag.translation.width < -60 { close() }
                                    })
                            }
                        }
                        // A swipe in from the left edge opens the chats.
                        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                            if !sidebarOpen, drag.startLocation.x < 30, drag.translation.width > 70 {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { sidebarOpen = true }
                            }
                        })
                    }
                }
            }
        }
        .readsWidthClass()
        .tint(Design.palette().accent)
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { sidebarOpen = false }
    }
}

/// The gap between the chats and the chat, with the grip in its middle:
/// drag it to give the chats more or less room, as on the Mac.
private struct PanelGap: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        DividerGrip(axis: .vertical, hover: hover || start != nil, dragging: start != nil)
            .frame(width: Design.panelGap)
            .frame(maxHeight: .infinity)
            // A wider place to take hold of than the gap itself.
            .frame(width: 24)
            .contentShape(Rectangle())
            .padding(.horizontal, (Design.panelGap - 24) / 2)
            .zIndex(1)
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + Double(drag.translation.width), 240), 420)
                }
                .onEnded { _ in start = nil })
            .accessibilityHidden(true)
    }
}
