// Tessera/Terminal/TerminalResizeCoalescer.swift
// Apple compatibility spelling. The rule, the 28ms modal-storm measurement
// that produced it, and the `settleSeconds` constant now live in
// `TesseraSessionCore/TerminalResizeCoalescer.swift` so mosh, SSH, tmux, and
// the Android client all coalesce identically.

import Foundation
import TesseraSessionCore

typealias TerminalResizeCoalescer = TesseraSessionCore.TerminalResizeCoalescer
