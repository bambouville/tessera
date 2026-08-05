import Observation

enum ModifierBehavior: String, CaseIterable, Codable {
    case oneShot
    case sticky
}

@Observable
final class ModifierState {
    private(set) var armed: ArmedModifiers = .none
    var behavior: ModifierBehavior = .oneShot
    private(set) var suppressesSoftwareKeyboardReclaim = false
    @ObservationIgnored private var resignSoftwareKeyboard: (() -> Bool)?
    @ObservationIgnored private var becomeSoftwareKeyboard: (() -> Bool)?

    @discardableResult
    func tap(_ chip: AccessoryChip) -> ArmedModifiers {
        switch chip {
        case .ctrl:
            armed.ctrl.toggle()
        case .alt:
            armed.alt.toggle()
        case .shift:
            armed.shift.toggle()
        default:
            precondition(false, "ModifierState.tap requires a modifier chip")
        }

        return armed
    }

    @discardableResult
    func consume() -> ArmedModifiers {
        let snapshot = armed

        if behavior == .oneShot {
            armed = .none
        }

        return snapshot
    }

    func cancel() {
        armed = .none
    }

    @discardableResult
    func dismissSoftwareKeyboard() -> Bool {
        suppressesSoftwareKeyboardReclaim = true
        return resignSoftwareKeyboard?() ?? false
    }

    func noteSoftwareKeyboardRequested(
        resign: @escaping () -> Bool,
        become: @escaping () -> Bool = { false }
    ) {
        resignSoftwareKeyboard = resign
        becomeSoftwareKeyboard = become
        suppressesSoftwareKeyboardReclaim = false
    }

    @discardableResult
    func showSoftwareKeyboard() -> Bool {
        suppressesSoftwareKeyboardReclaim = false
        return becomeSoftwareKeyboard?() ?? false
    }
}
