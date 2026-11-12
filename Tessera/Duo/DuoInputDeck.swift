import SwiftUI

struct DuoFoldedInputActiveKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The visible session's free desk, globally: the folded deck's lower half
/// below its bar and replies, as it was when the keyboard was last down,
/// and the fold's top above it. Duo's workspace puts the context on the
/// desk; the session keeps its floating chrome above the fold.
struct DuoDesk: Equatable {
    var area: CGRect
    var foldTop: CGFloat
}

struct DuoDeskAreaKey: PreferenceKey {
    static let defaultValue: DuoDesk? = nil
    static func reduce(value: inout DuoDesk?, nextValue: () -> DuoDesk?) { value = value ?? nextValue() }
}

enum TerminalKeyboardLayoutPolicy {
    static func layout(
        proposedHeight: CGFloat, retainedHeight: CGFloat,
        resizesTerminal: Bool, foldedLayoutActive: Bool
    ) -> (height: CGFloat, lift: CGFloat) {
        let usesProposal = resizesTerminal || foldedLayoutActive
        return (usesProposal ? proposedHeight : retainedHeight,
                usesProposal ? 0 : max(0, retainedHeight - proposedHeight))
    }
}

extension EnvironmentValues {
    /// Inside Duo's folded input deck, which places the accessory bar itself.
    @Entry var duoFoldedDeck = false
    /// Where a session's folded deck puts the accessory bar; nil elsewhere.
    @Entry var duoDeckPlacement: DuoDeckPlacement? = nil
    /// The folded deck's width, which the pill measures its drags against.
    @Entry var duoDeckWidth: CGFloat = 0
    /// How far rows on the hinge reach up over the content: the open bar
    /// while typing, with any replies stacked on it. The content keeps its
    /// size under them; a terminal slides up only as far as its caret needs.
    @Entry var duoDeckCover: CGFloat = 0
}

/// How far a terminal slides up so the rows over its bottom edge clear the
/// caret, the way it avoids a floating keyboard.
enum DuoDeckCaretPolicy {
    /// - Parameters:
    ///   - cover: how far the rows reach up over the terminal.
    ///   - below: clear space under the caret's row, or nil when the caret
    ///     cannot be followed (a full-screen app, a pane grid, find). The
    ///     terminal then keeps its bottom rows in view, as for the keyboard.
    static func lift(cover: CGFloat, below: CGFloat?) -> CGFloat {
        guard cover > 0 else { return 0 }
        guard let below else { return cover }
        return max(0, cover - max(0, below))
    }
}

/// Where a session's accessory bar sits in laptop pose.
enum DuoDeckBarPlacement: Equatable {
    /// Typing with the bar open, a composer while typing, or one that rests
    /// there (`DuoDeckBar.restsOnHinge`): a full row on the hinge.
    case hinge
    /// Typing with the bar closed: its two buttons, above the hinge at its edge.
    case pill
    /// Not typing: a full row at the top of the desk half.
    case desk
}

/// A session's laptop-pose bar settings, which the user changes from the bar.
struct DuoDeckBar: Equatable {
    var openWhileTyping: Bool
    var edge: HorizontalEdge
    /// A text field's row (a composer, a find field) has no pill: it rests
    /// on the hinge while typing, with the content ending above it, and
    /// opens at the top of the desk after.
    var isComposer = false
    /// The desk is a page of its own (Agent Center's thread list), not
    /// replies to the bar: while typing it waits under the keyboard, hidden,
    /// instead of stacking over the hinge.
    var deskStaysDown = false
    /// The row docks at the bottom of the content, just above the fold, with
    /// the keyboard down too, rather than opening at the top of the desk.
    var restsOnHinge = false

    static let composer = DuoDeckBar(openWhileTyping: false, edge: .trailing, isComposer: true)
    /// Agent Center's laptop viewer: its composer stays on the hinge in both
    /// keyboard states, and the thread list on the desk steps aside while
    /// the keyboard covers it.
    static let viewerComposer = DuoDeckBar(
        openWhileTyping: false, edge: .trailing, isComposer: true, deskStaysDown: true, restsOnHinge: true
    )
}

struct DuoDeckPlacement: Equatable {
    var bar: DuoDeckBarPlacement
    var keyboardUp: Bool
    /// The pill's edge, and the side of every row that holds the bar's buttons.
    var edge: HorizontalEdge = .trailing
    /// The content ends above the deck and desk on the hinge instead of
    /// running under them.
    var clearsContent = false
    /// See `DuoDeckBar.deskStaysDown`.
    var deskStaysDown = false
    /// See `DuoDeckBar.restsOnHinge`.
    var restsOnHinge = false

    /// The terminal keeps the whole top half in every state, and nothing the
    /// bar does resizes it. While typing, the open bar floats on the hinge
    /// over the terminal's bottom rows and the closed bar is a pill at its
    /// edge; with the keyboard down, either opens below the hinge. A
    /// composer trades the pill for the hinge, and one that rests there stays.
    static func resolve(_ settings: DuoDeckBar, keyboardUp: Bool) -> DuoDeckPlacement {
        let typingBar: DuoDeckBarPlacement = settings.openWhileTyping || settings.isComposer ? .hinge : .pill
        let restingBar: DuoDeckBarPlacement = settings.restsOnHinge ? .hinge : .desk
        return DuoDeckPlacement(
            bar: keyboardUp ? typingBar : restingBar,
            keyboardUp: keyboardUp, edge: settings.edge, clearsContent: settings.isComposer,
            deskStaysDown: settings.deskStaysDown, restsOnHinge: settings.restsOnHinge
        )
    }

    var isPill: Bool { bar == .pill }

    /// Agent replies have no room while the pill is up; the puck's petals
    /// and the chevron's dot carry them instead. A desk that stays down
    /// waits under the keyboard.
    var hidesDesk: Bool { keyboardUp && (isPill || deskStaysDown) }

    /// While typing, the desk stacks over a bar on the hinge.
    var stacksDeskOverHinge: Bool { keyboardUp && bar == .hinge && !deskStaysDown }
}

enum DuoDeckRole {
    case content, deck, desk
}

struct DuoDeckRoleKey: LayoutValueKey {
    static let defaultValue = DuoDeckRole.content
}

struct DuoDeckFrames: Equatable {
    var content: CGRect
    var deck: CGRect
    var desk: CGRect?
}

struct DuoFoldedInputLayout<Content: View, Deck: View, Desk: View>: View {
    @Environment(\.designTokens) private var T
    @Environment(\.displayScale) private var displayScale
    @Environment(\.softwareKeyboardUp) private var sessionKeyboardUp
    @State private var observedFold: DuoFold?
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var deskArea: DuoDesk?
    /// Edges in the layout's own space, for `cover`.
    @State private var contentBottom: CGFloat?
    @State private var deckTop: CGFloat?
    @State private var deskTop: CGFloat?

    private let isEnabled: Bool
    private let suppliedFold: DuoFold?
    private let observesFold: Bool
    private let contentReserve: CGFloat
    private let bar: DuoDeckBar?
    private let hasDesk: Bool
    private let publishesDesk: Bool
    private let content: Content
    private let deck: Deck
    private let desk: Desk

    /// Sessions share this settled fold with their keyboard layout policy.
    /// `bar` lets the bar fold to a pill while typing and open below the
    /// hinge after; `desk` (agent replies) then sits under the hinge, or
    /// above the open bar while typing. The content keeps the whole top half
    /// and reads how far rows on the hinge cover it from `duoDeckCover`. The
    /// visible session `publishesDesk`: what the desk leaves free below its
    /// replies.
    init(isEnabled: Bool, fold: DuoFold?, bar: DuoDeckBar?, publishesDesk: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder deck: () -> Deck, @ViewBuilder desk: () -> Desk) {
        self.isEnabled = isEnabled
        self.suppliedFold = fold
        self.observesFold = false
        self.contentReserve = 0
        self.bar = bar
        self.hasDesk = true
        self.publishesDesk = publishesDesk
        self.content = content()
        self.deck = deck()
        self.desk = desk()
    }

    /// Observes its own fold, for screens outside a session: a conversation's
    /// composer, a find field. Their keyboard comes from the proposal.
    init(isEnabled: Bool, bar: DuoDeckBar, publishesDesk: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder deck: () -> Deck, @ViewBuilder desk: () -> Desk) {
        self.isEnabled = isEnabled
        self.suppliedFold = nil
        self.observesFold = true
        self.contentReserve = 0
        self.bar = bar
        self.hasDesk = true
        self.publishesDesk = publishesDesk
        self.content = content()
        self.deck = deck()
        self.desk = desk()
    }

    /// The session's keyboard, or one the proposal shows reaching the fold.
    private func keyboardUp(fold: DuoFold?) -> Bool {
        sessionKeyboardUp || (bar != nil && height > 0
            && DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: width, height: height), fold: fold))
    }

    @ViewBuilder
    var body: some View {
        if observesFold {
            layout.onDuoFoldChange { settledFold in
                if observedFold != settledFold { observedFold = settledFold }
            }
        } else {
            layout
        }
    }

    private var layout: some View {
        let fold = observesFold ? observedFold : suppliedFold
        let isFolded = isEnabled && fold?.splitsSideBySide == false
        let keyboardUp = keyboardUp(fold: isEnabled ? fold : nil)
        let placement = bar.map { DuoDeckPlacement.resolve($0, keyboardUp: keyboardUp) }
            ?? DuoDeckPlacement(bar: .hinge, keyboardUp: keyboardUp)
        return DuoInputDeckLayout(
            fold: isEnabled ? fold : nil,
            contentReserve: contentReserve,
            placement: placement,
            bar: bar
        ) {
            content
                .environment(\.duoDeckCover, cover(placement: placement, isFolded: isFolded))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(DuoFoldedInputSpace.name)).maxY } action: {
                    contentBottom = $0
                }
            if hasDesk {
                VStack(spacing: 0) {
                    desk
                    if isFolded {
                        // Measured with no height of its own, so the replies
                        // alone size the desk; placed, it fills what they leave.
                        Color.clear
                            .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
                            .onGeometryChange(for: DeskSample.self) { proxy in
                                let area = proxy.frame(in: .global)
                                let local = proxy.frame(in: .named(DuoFoldedInputSpace.name))
                                // The layout's own container, from the pass that
                                // placed this desk: a proposal-read keyboard shows
                                // there before `keyboardUp` catches up.
                                let container = proxy.bounds(of: .named(DuoFoldedInputSpace.name))?.size
                                return DeskSample(
                                    desk: DuoDesk(area: area, foldTop: area.minY - local.minY + (fold?.frame.minY ?? local.minY)),
                                    typing: container.map { DuoInputDeckLayout.keyboardCoversDesk(container: $0, fold: fold) } ?? false
                                )
                            } action: { sample in
                                // The keyboard covers the desk while typing. The
                                // context stays put under it, mounted and unseen,
                                // so its pages don't reload with every keystroke's
                                // keyboard; it only moves with the bar and replies.
                                // A desk stacked over a hinge row is typing too.
                                let desk = sample.desk
                                if !keyboardUp, !sample.typing, desk.area.minY >= desk.foldTop { deskArea = desk }
                            }
                    }
                }
                    .environment(\.duoFoldedDeck, isFolded)
                    .frame(maxWidth: isFolded ? .infinity : nil,
                           maxHeight: isFolded ? .infinity : nil, alignment: .top)
                    .background { if isFolded { panel } }
                    .opacity(isFolded && placement.hidesDesk ? 0 : 1)
                    .allowsHitTesting(!(isFolded && placement.hidesDesk))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(DuoFoldedInputSpace.name)).minY } action: {
                        deskTop = $0
                    }
                    .layoutValue(key: DuoDeckRoleKey.self, value: .desk)
            }
            if bar == nil {
                deck
                    .environment(\.duoFoldedDeck, isFolded)
                    .frame(maxWidth: isFolded ? .infinity : nil,
                           maxHeight: isFolded ? .infinity : nil, alignment: .top)
                    .background { if isFolded { panel } }
                    .layoutValue(key: DuoDeckRoleKey.self, value: .deck)
            } else {
                // The bar draws its own material, as a row or as the pill.
                deck
                    .environment(\.duoFoldedDeck, isFolded)
                    .environment(\.duoDeckPlacement, isFolded ? placement : nil)
                    .environment(\.duoDeckWidth, width)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(DuoFoldedInputSpace.name)).minY } action: {
                        deckTop = $0
                    }
                    .layoutValue(key: DuoDeckRoleKey.self, value: .deck)
            }
        }
        .coordinateSpace(.named(DuoFoldedInputSpace.name))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            width = size.width
            // Only a bar that follows a proposal-read keyboard needs it.
            if bar != nil, height != size.height { height = size.height }
        }
        .preference(key: DuoFoldedInputActiveKey.self, value: isFolded)
        .preference(
            key: DuoDeskAreaKey.self,
            value: publishesDesk && isFolded ? deskArea.flatMap(Self.usableDesk) : nil
        )
    }

    private struct DeskSample: Equatable {
        var desk: DuoDesk
        var typing: Bool
    }

    /// Only full rows on the hinge cover the content: the pill sits in its
    /// corner, and a composer's content already ends above its rows.
    private func cover(placement: DuoDeckPlacement, isFolded: Bool) -> CGFloat {
        guard isFolded, placement.keyboardUp, placement.bar == .hinge, !placement.clearsContent,
              let contentBottom, let deckTop else { return 0 }
        let top = placement.stacksDeskOverHinge ? min(deckTop, deskTop ?? deckTop) : deckTop
        return max(0, contentBottom - top)
    }

    /// A desk too short for the context's header and a row is no desk.
    private static func usableDesk(_ desk: DuoDesk) -> DuoDesk? {
        desk.area.height >= 88 ? desk : nil
    }

    private var panel: some View {
        T.panelBg
            .overlay(alignment: .top) {
                Rectangle().fill(T.border).frame(height: 1 / displayScale)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum DuoFoldedInputSpace {
    static let name = "duo-folded-input"
}

extension DuoFoldedInputLayout where Desk == EmptyView {
    init(isEnabled: Bool, @ViewBuilder content: () -> Content, @ViewBuilder deck: () -> Deck) {
        self.isEnabled = isEnabled
        self.suppliedFold = nil
        self.observesFold = true
        self.contentReserve = 0
        self.bar = nil
        self.hasDesk = false
        self.publishesDesk = false
        self.content = content()
        self.deck = deck()
        self.desk = EmptyView()
    }

    /// The whole deck rests on the hinge in every keyboard state.
    init(isEnabled: Bool, fold: DuoFold?, contentReserve: CGFloat = 0,
         @ViewBuilder content: () -> Content, @ViewBuilder deck: () -> Deck) {
        self.isEnabled = isEnabled
        self.suppliedFold = fold
        self.observesFold = false
        self.contentReserve = contentReserve
        self.bar = nil
        self.hasDesk = false
        self.publishesDesk = false
        self.content = content()
        self.deck = deck()
        self.desk = EmptyView()
    }
}

/// The children keep their identity as the settled fold comes and goes.
/// Delegating the ordinary path also preserves VStack's flexibility ordering.
struct DuoInputDeckLayout: Layout {
    var fold: DuoFold?
    var contentReserve: CGFloat = 0
    var placement = DuoDeckPlacement(bar: .hinge, keyboardUp: false)
    /// The bar's settings, to resolve `placement` again for a keyboard that
    /// only the proposal reports.
    var bar: DuoDeckBar?

    /// The pill keeps clear of the screen's edge and of the hinge.
    static let pillInset: CGFloat = 8
    static let pillGap: CGFloat = 6

    static var layoutProperties: LayoutProperties { VStackLayout.layoutProperties }

    private var stack: AnyLayout { AnyLayout(VStackLayout(spacing: 0)) }

    func makeCache(subviews: Subviews) -> AnyLayout.Cache {
        stack.makeCache(subviews: subviews)
    }

    func updateCache(_ cache: inout AnyLayout.Cache, subviews: Subviews) {
        stack.updateCache(&cache, subviews: subviews)
    }

    func spacing(subviews: Subviews, cache: inout AnyLayout.Cache) -> ViewSpacing {
        stack.spacing(subviews: subviews, cache: &cache)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout AnyLayout.Cache) -> CGSize {
        if let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite,
           Self.split(container: CGSize(width: width, height: height), fold: fold) != nil {
            return CGSize(width: width, height: height)
        }
        let ordinary = stack.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
        let size = CGSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ordinary.width,
            height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? ordinary.height
        )
        guard Self.split(container: size, fold: fold) != nil else { return ordinary }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout AnyLayout.Cache) {
        let content = subviews.first { $0[DuoDeckRoleKey.self] == .content }
        let deck = subviews.first { $0[DuoDeckRoleKey.self] == .deck }
        let desk = subviews.first { $0[DuoDeckRoleKey.self] == .desk }
        let folded = fold?.splitsSideBySide == false
        let placement = resolved(in: bounds.size)
        let deckSize: CGSize = {
            guard folded, let deck else { return .zero }
            // The pill takes its own width; rows take the deck's.
            if placement.isPill { return deck.sizeThatFits(.unspecified) }
            return CGSize(
                width: bounds.width,
                height: deck.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            )
        }()
        let deskHeight = folded
            ? desk.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height } : nil
        guard let content, let frames = Self.frames(
            container: bounds.size, fold: fold, placement: placement,
            deckSize: deckSize, deskHeight: deskHeight, contentReserve: contentReserve
        ) else {
            stack.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
            return
        }
        var placed: [(LayoutSubview, CGRect)] = [(content, frames.content)]
        if let deck { placed.append((deck, frames.deck)) }
        if let desk, let rect = frames.desk { placed.append((desk, rect)) }
        for (subview, rect) in placed {
            subview.place(
                at: CGPoint(x: bounds.minX + rect.midX, y: bounds.minY + rect.minY),
                anchor: .top,
                proposal: ProposedViewSize(rect.size)
            )
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout AnyLayout.Cache) -> CGFloat? {
        stack.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout AnyLayout.Cache) -> CGFloat? {
        stack.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }

    /// The deck rests on the hinge in every keyboard state. Partially folded,
    /// iOS reports the keyboard from the fold down and takes touches above its
    /// keys, so the hinge is the lowest place a bar still works; it is also
    /// where iOS seats input accessories. The content keeps `contentReserve`
    /// clear above the deck, so the grid never resizes with the keyboard; a
    /// taller deck (agent replies) overlaps it instead.
    static func split(
        container: CGSize, fold: DuoFold?, minimumDeckHeight: CGFloat = 0, contentReserve: CGFloat = 0
    ) -> (content: CGRect, deck: CGRect)? {
        guard let fold, !fold.splitsSideBySide else { return nil }
        // Keyboard avoidance reduces the proposal from below. Keep the upper
        // content's proposal anchored to the fold, even with no deck space left.
        let fullSize = CGSize(width: container.width, height: max(container.height, fold.frame.maxY))
        guard var split = DuoPaneGeometry.deckSplit(container: fullSize, fold: fold) else { return nil }
        let hinge = split.content.maxY
        split.content.size.height = max(0, hinge - max(0, contentReserve))
        // A keyboard reaching above the hinge lifts only the deck.
        split.deck.origin.y = max(0, min(hinge, container.height) - max(0, minimumDeckHeight))
        split.deck.size.height = max(0, container.height - split.deck.minY)
        return split
    }

    /// Every placement leaves the content's frame alone across the keyboard
    /// and the bar: rows on the hinge float over it unless `contentReserve`
    /// keeps them clear.
    ///
    /// - `hinge`: `split`, with the desk stacked over the bar while typing
    ///   (or waiting under the keyboard, if it stays down) and filling the
    ///   desk half after.
    /// - `pill`: the content keeps the whole top half; the deck takes its own
    ///   size at one edge, just above the hinge.
    /// - `desk`: the content keeps the top half; the bar opens at the top of
    ///   the desk half and the desk fills the rest.
    static func frames(
        container: CGSize, fold: DuoFold?, placement: DuoDeckPlacement,
        deckSize: CGSize, deskHeight: CGFloat?, contentReserve: CGFloat = 0
    ) -> DuoDeckFrames? {
        guard let fold, !fold.splitsSideBySide else { return nil }
        let fullSize = CGSize(width: container.width, height: max(container.height, fold.frame.maxY))
        guard let halves = DuoPaneGeometry.deckSplit(container: fullSize, fold: fold),
              let split = split(
                container: container, fold: fold, minimumDeckHeight: deckSize.height,
                contentReserve: placement.bar == .hinge ? contentReserve : 0
              )
        else { return nil }
        let width = halves.content.width
        let deskTop = halves.deck.minY
        let floor = min(halves.content.maxY, container.height)
        let deck: CGRect
        switch placement.bar {
        case .hinge:
            // A resting row takes its own height, not the rest of the screen.
            deck = placement.restsOnHinge
                ? CGRect(x: split.deck.minX, y: split.deck.minY, width: split.deck.width,
                         height: min(split.deck.height, deckSize.height))
                : split.deck
        case .pill:
            let pillWidth = min(deckSize.width, max(0, width - 2 * pillInset))
            deck = CGRect(
                x: placement.edge == .leading ? pillInset : width - pillInset - pillWidth,
                y: max(0, floor - pillGap - deckSize.height),
                width: pillWidth, height: deckSize.height
            )
        case .desk:
            // A keyboard that reaches into the desk lifts the bar, never past the hinge.
            let top = max(floor - deckSize.height, min(deskTop, container.height - deckSize.height))
            deck = CGRect(x: 0, y: max(0, top), width: width, height: deckSize.height)
        }
        var desk: CGRect?
        if let deskHeight {
            if placement.keyboardUp {
                desk = placement.stacksDeskOverHinge
                    ? CGRect(x: 0, y: max(0, deck.minY - deskHeight), width: width, height: deskHeight)
                    : CGRect(x: 0, y: deskTop, width: width, height: deskHeight)
            } else {
                let top = placement.bar == .desk ? deck.maxY : deskTop
                desk = CGRect(x: 0, y: top, width: width, height: max(deskHeight, container.height - top))
            }
        }
        var content = split.content
        if placement.clearsContent, placement.bar == .hinge {
            let above = placement.stacksDeskOverHinge ? desk?.minY ?? deck.minY : deck.minY
            content.size.height = max(0, min(content.maxY, above) - content.minY)
        }
        return DuoDeckFrames(content: content, deck: deck, desk: desk)
    }

    /// Partially folded, iOS reports the keyboard from the fold's top, so a
    /// proposal ending above the fold's bottom has the keyboard under it. A
    /// hardware keyboard's shortcut bar leaves the desk half standing.
    static func keyboardCoversDesk(container: CGSize, fold: DuoFold?) -> Bool {
        guard let fold, !fold.splitsSideBySide else { return false }
        return container.height < fold.frame.maxY - 0.5
    }

    /// Screens with no session to report the keyboard read it from their
    /// proposal, in the same layout pass that the keyboard shortens it.
    private func resolved(in size: CGSize) -> DuoDeckPlacement {
        guard let bar, !placement.keyboardUp, Self.keyboardCoversDesk(container: size, fold: fold) else {
            return placement
        }
        return DuoDeckPlacement.resolve(bar, keyboardUp: true)
    }
}

struct DuoAgentRepliesRow: View {
    @Environment(\.designTokens) private var T
    private let prompt: AgentPrompt?
    private let onReply: (AgentPromptOption) -> Void

    init(prompt: AgentPrompt?, onReply: @escaping (AgentPromptOption) -> Void) {
        self.prompt = prompt
        self.onReply = onReply
    }

    var options: [AgentPromptOption] { prompt?.options ?? [] }

    var body: some View {
        if !options.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        Button { reply(option) } label: {
                            Text(option.label)
                                .font(Typography.tesseraMono(size: 10.5, weight: option.isDefault ? .medium : .regular))
                                .foregroundStyle(foreground(for: option))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .frame(minWidth: 44, minHeight: 44)
                                .background(option.isDefault ? T.accentSoft : T.inputBgSoft,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(border(for: option), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("answer \(option.label)")
                        .accessibilityIdentifier("duo-agent-reply-\(option.id)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("duo-agent-replies")
        }
    }

    func reply(_ option: AgentPromptOption) { onReply(option) }

    static func tint(for option: AgentPromptOption) -> SwipePadPetalModel.Tint {
        SwipePadPetalLayout.tint(for: option)
    }

    private func foreground(for option: AgentPromptOption) -> Color {
        switch Self.tint(for: option) {
        case .negative: return T.red
        case .caution: return T.amber
        case .affirmative, .neutral: return option.isDefault ? T.fg : T.fgMuted
        }
    }

    private func border(for option: AgentPromptOption) -> Color {
        guard option.isDefault else { return T.border }
        switch Self.tint(for: option) {
        case .negative: return T.red.opacity(0.35)
        case .caution: return T.amber.opacity(0.35)
        case .affirmative, .neutral: return T.accent.opacity(0.35)
        }
    }
}

extension View {
    /// Observes the fold inside the session's keyboard translation. Entering
    /// the folded layout drops that lift and moves this view down by it, so
    /// the fold is reported where the view comes to rest: one fold per pose.
    func onKeyboardUnliftedDuoFoldChange(_ action: @escaping (DuoFold?) -> Void) -> some View {
        modifier(KeyboardUnliftedDuoFold(action: action))
    }
}

private struct KeyboardUnliftedDuoFold: ViewModifier {
    @Environment(\.softwareKeyboardLift) private var lift
    var action: (DuoFold?) -> Void

    func body(content: Content) -> some View {
        content.onDuoFoldChange(contentLift: lift, action)
    }
}

extension DuoDeckBar {
    /// With the accessory bar off there is no pill to fold to or flag a
    /// waiting agent, so the replies keep their place over the hinge.
    init(_ appearance: AppearancePreferences) {
        self.init(
            openWhileTyping: appearance.duoBarOpenWhileTyping || !appearance.showAccessoryBar,
            edge: appearance.duoBarEdge == "leading" ? .leading : .trailing
        )
    }
}
