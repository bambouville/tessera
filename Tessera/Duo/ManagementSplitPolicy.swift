import Foundation

/// Management lists share their detail's space in the rail shell, and across
/// a settled side-to-side (laptop) fold, which has no rail. Folds exist only
/// on Duo, so every other device keeps the single arrangement.
enum ManagementSplitPolicy {
    struct Split: Equatable {
        var list: CGRect
        var detail: CGRect
    }

    enum Arrangement: Equatable {
        case single
        case listBesideDetail(listWidth: CGFloat)
        case listOverDetail(split: Split)
    }

    /// Header, section picker, actions, and enough of a scrolling form.
    static let minimumDetailHeight: CGFloat = 240

    private static let minimumListWidth: CGFloat = 320
    private static let idealListWidth: CGFloat = 343
    private static let minimumDetailWidth: CGFloat = 480

    static func arrangement(isRailMode: Bool, container: CGSize, fold: DuoFold?) -> Arrangement {
        guard isRailMode || fold?.splitsSideBySide == false else { return .single }
        if let split = foldSplit(container: container, fold: fold), let fold {
            return fold.splitsSideBySide
                ? .listBesideDetail(listWidth: split.list.width)
                : .listOverDetail(split: split)
        }
        guard container.width >= minimumListWidth + minimumDetailWidth else { return .single }
        return .listBesideDetail(listWidth: min(idealListWidth, container.width - minimumDetailWidth))
    }

    /// Over the laptop's fold, SwiftUI ends the container at the keyboard,
    /// which rises from the fold: a field on the desk leaves its detail too
    /// little room. The detail then covers the list, above the fold, until
    /// the keyboard goes.
    static func detailFrame(_ split: Split) -> CGRect {
        split.detail.height < minimumDetailHeight ? split.list : split.detail
    }

    /// Both orientations use the workspace's clamped fold edges. Callers also
    /// use this for the gap beside a list; the fold never becomes pane content.
    static func foldSplit(container: CGSize, fold: DuoFold?) -> Split? {
        guard fold != nil else { return nil }
        // Only the fold divides here. A fold the geometry rejects must not
        // fall through to its unfolded split, which would give the list its
        // ideal width of zero.
        let layout = DuoPaneGeometry.layout(DuoPaneRequest(
            container: container, fold: fold, contextHidden: false, fullScreen: false,
            swapped: false, mainTakesInput: false, mainIdealWidth: 0, minimumMainWidth: .infinity
        ))
        guard let detail = layout.contextSlot else { return nil }
        return Split(list: layout.mainSlot, detail: detail)
    }
}

/// The pushed path and the split's selected row project the same section.
struct ManagementSelection<Section: Hashable>: Equatable {
    var section: Section?

    var phonePath: [Section] {
        get { section.map { [$0] } ?? [] }
        set { section = newValue.last }
    }

    func detail(defaultSection: Section) -> Section {
        section ?? defaultSection
    }

    mutating func retainDetail(for arrangement: ManagementSplitPolicy.Arrangement, defaultSection: Section) {
        guard arrangement != .single, section == nil else { return }
        section = defaultSection
    }
}
