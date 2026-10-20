import Foundation
import TesseraAgentCore

private struct ComposerEvidenceRequest: Decodable {
    let provider: String
    let visibleText: String
    let cursorLine: String?
    let text: String
    let queueWhenWorking: Bool?
    let cursorRow: Int?
    let cursorColumn: Int?
    let literalImagePathsOnly: Bool?
    let safetyOnly: Bool?
    let requireEmpty: Bool?
    let cursorVisible: Bool?
    let screen: TerminalScreenEvidence?
}

private struct ComposerInsertionRequest: Decodable {
    let provider: String
    let text: String
    let bracketedPasteEnabled: Bool
}

@_cdecl("tessera_agent_composer_insertion")
public func tesseraAgentComposerInsertion(inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= 262_144,
          let request = try? JSONDecoder().decode(ComposerInsertionRequest.self, from: Data(bytes: inputBytes, count: inputCount)),
          let insertion = AgentTextInsertion.bytes(provider: request.provider, text: request.text, bracketedPasteEnabled: request.bracketedPasteEnabled)
    else { return -1 }
    let encoded = Array(insertion.base64EncodedString().utf8)
    guard let outputBytes, outputCapacity > 0 else { return Int32(encoded.count) }
    guard encoded.count <= outputCapacity else { return -1 }
    encoded.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress { outputBytes.update(from: base, count: buffer.count) }
    }
    return Int32(encoded.count)
}

/// -1 unavailable, 0 recognized absence, 1 matching Return composer, 2 matching
/// Tab-to-queue composer. Native clients must not infer absence from -1.
/// The 2 MiB wire budget admits the complete 65,536-cell typed grid plus bounded
/// plain-text/action fields. Core still independently limits glyphs to 64 KiB.
@_cdecl("tessera_agent_composer_assess")
public func tesseraAgentComposerAssess(inputBytes: UnsafePointer<UInt8>?, inputCount: Int) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= 2 * 1_024 * 1_024,
          let request = try? JSONDecoder().decode(ComposerEvidenceRequest.self, from: Data(bytes: inputBytes, count: inputCount))
    else { return -1 }
    if request.safetyOnly == true {
        switch AgentComposerEvidence.safety(provider: request.provider, visibleText: request.visibleText,
            cursorRow: request.cursorRow, cursorColumn: request.cursorColumn, cursorVisible: request.cursorVisible,
            requireEmpty: request.requireEmpty == true, queueWhenWorking: request.queueWhenWorking == true, text: request.text, screen: request.screen, literalImagePathsOnly: request.literalImagePathsOnly == true) {
        case .readyReturn: return 1
        case .readyTab: return 2
        case .blocked: return 3
        case .occupied: return 4
        case .unavailable: return -1
        }
    }
    switch AgentComposerEvidence.presence(provider: request.provider, visibleText: request.visibleText, cursorLine: request.cursorLine, text: request.text, cursorRow: request.cursorRow) {
    case .unavailable: return -1
    case .absent: return 0
    case .present:
        return AgentComposerEvidence.submissionKey(provider: request.provider, visibleText: request.visibleText,
            cursorLine: request.cursorLine, text: request.text, queueWhenWorking: request.queueWhenWorking == true, cursorRow: request.cursorRow) == .tab ? 2 : 1
    }
}

@_cdecl("tessera_agent_composer_matches")
public func tesseraAgentComposerMatches(inputBytes: UnsafePointer<UInt8>?, inputCount: Int) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= 256 * 1_024,
          let request = try? JSONDecoder().decode(ComposerEvidenceRequest.self, from: Data(bytes: inputBytes, count: inputCount))
    else { return 0 }
    return AgentComposerEvidence.matches(provider: request.provider, visibleText: request.visibleText, cursorLine: request.cursorLine, text: request.text, cursorRow: request.cursorRow) ? 1 : 0
}
