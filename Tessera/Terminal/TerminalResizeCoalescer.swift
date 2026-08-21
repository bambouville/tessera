// Tessera/Terminal/TerminalResizeCoalescer.swift
// Decides which terminal size changes are worth telling the remote about.
//
// Presenting a modal over a session makes the terminal shrink and come back:
// a capture shows 976 -> 944 -> 976pt in 28ms, which cost two client resizes,
// two `refresh-client -C` round trips, two grid-authority generations, and
// two full repaints of a 33,000pt-tall pane — for a size that never changed.
// The frame right after that storm took 137.7ms. A repaint racing a resize is
// also the shape that leaves stale content on screen.
//
// Pure so the decision can be tested without a terminal or a host. The view
// owns the clock; this owns the rule.

import Foundation

struct TerminalResizeCoalescer {
    struct Size: Equatable {
        var cols: Int
        var rows: Int
    }

    enum Decision: Equatable {
        /// Deliver now — nothing has been delivered yet, so the session
        /// cannot start without it.
        case send
        /// Hold it for the settle window; deliver if nothing supersedes it.
        case wait
        /// The size came back to what the remote already has. Whatever
        /// happened in between never happened as far as the remote is
        /// concerned.
        case drop
    }

    /// Long enough to swallow a modal's shrink-and-restore (28ms measured),
    /// short enough that a real resize is not perceptibly late.
    static let settleSeconds: TimeInterval = 0.12

    private(set) var lastDelivered: Size?
    /// Set while a size is waiting out the settle window.
    private(set) var pending: Size?

    /// Call for every size the terminal view reports.
    mutating func note(_ size: Size) -> Decision {
        guard let lastDelivered else {
            self.lastDelivered = size
            pending = nil
            return .send
        }
        guard size != lastDelivered else {
            // Covers both a repeat of the current size and a transient that
            // has returned to it. Either way the remote needs nothing.
            pending = nil
            return .drop
        }
        pending = size
        return .wait
    }

    /// Call when the settle window expires for `size`. Returns false if the
    /// wait was superseded, so a stale timer cannot deliver an old size.
    mutating func settle(_ size: Size) -> Bool {
        guard pending == size else { return false }
        pending = nil
        lastDelivered = size
        return true
    }
}
