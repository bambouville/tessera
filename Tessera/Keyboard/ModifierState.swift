enum ModifierBehavior: String, CaseIterable, Codable {
    case oneShot
    case sticky
}

final class ModifierState {
    private(set) var armed: ArmedModifiers = .none
    var behavior: ModifierBehavior = .oneShot

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
}
