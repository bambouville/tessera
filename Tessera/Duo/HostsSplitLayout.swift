import Foundation

/// Hosts keep one explicit selection. Geometry never chooses a host or
/// changes the editor's identity; it only places that editor's existing tree.
struct HostsSplitLayout: Equatable {
    enum Detail: Equatable {
        case hidden
        case empty
        case editor(UUID)
    }

    var arrangement: ManagementSplitPolicy.Arrangement
    var list: CGRect
    var detail: CGRect
    var editor: CGRect
    var detailContent: Detail

    var isSplit: Bool { arrangement != .single }
    var editorCoversList: Bool { isSplit && editor.intersects(list) }

    private static let minimumEditorHeight = ManagementSplitPolicy.minimumDetailHeight

    static func layout(
        isPhone: Bool, isRailMode: Bool, container: CGSize, fold: DuoFold?, selectedHostID: UUID?,
        isSearching: Bool = false, retainedEditorSize: CGSize? = nil
    ) -> HostsSplitLayout {
        let size = CGSize(width: max(0, container.width), height: max(0, container.height))
        let whole = CGRect(origin: .zero, size: size)
        let fold = isPhone ? fold : nil
        let arrangement = ManagementSplitPolicy.arrangement(
            isRailMode: isPhone && isRailMode, container: size, fold: fold
        )
        let split: ManagementSplitPolicy.Split
        switch arrangement {
        case .single:
            split = ManagementSplitPolicy.Split(list: whole, detail: whole)
        case .listBesideDetail(let listWidth):
            split = ManagementSplitPolicy.foldSplit(container: size, fold: fold)
                ?? ManagementSplitPolicy.Split(
                    list: CGRect(x: 0, y: 0, width: listWidth, height: size.height),
                    detail: CGRect(x: listWidth, y: 0, width: size.width - listWidth, height: size.height)
                )
        case .listOverDetail(let foldSplit):
            split = foldSplit
        }

        var editor = split.detail
        // SwiftUI reduces the container above the software keyboard. If that
        // leaves too little of the laptop's lower half for the form, cover the
        // list with the same editor, entirely above the fold. Its ScrollView
        // and bottom safe-area inset still own field scrolling and actions.
        if case .listOverDetail = arrangement, selectedHostID != nil, editor.height < minimumEditorHeight {
            if isSearching, let fold {
                // The list's quick-connect field owns this keyboard. Keep
                // the unfocused editor below the fold at its last size.
                editor.origin.y = max(editor.minY, fold.frame.maxY)
                editor.size.height = retainedEditorSize?.height ?? minimumEditorHeight
            } else {
                editor = split.list
            }
        }
        return HostsSplitLayout(
            arrangement: arrangement, list: split.list, detail: split.detail, editor: editor,
            detailContent: selectedHostID.map(Detail.editor) ?? (arrangement == .single ? .hidden : .empty)
        )
    }

    /// The split's list sits beside the editor, so removing another host
    /// there must keep that editor and its unsaved draft.
    static func deletionClearsSelection(deleted: UUID, selected: UUID?) -> Bool {
        selected.map { $0 == deleted } ?? true
    }

    static func usesSingleColumn(isSplit: Bool, width: CGFloat) -> Bool {
        isSplit && width <= 343
    }
}
