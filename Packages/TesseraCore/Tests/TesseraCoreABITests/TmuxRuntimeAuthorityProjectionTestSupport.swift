import Foundation
import TmuxControlCore
@testable import TesseraCoreABI

/// The Android copy-out contract, used by ABI tests through the exported call.
func projectRuntimeAuthority(
    handle: UnsafeMutableRawPointer?,
    authority: TmuxGridAuthoritySnapshot,
    capacity: Int = Int(CoreABICommand.maximumPayloadBytes),
    nullOutput: Bool = false,
    jsonOverride: Data? = nil
) -> (result: Int32, document: Data) {
    let input = jsonOverride ?? (try! SharedABI.encoder.encode(authority))
    var output = [UInt8](repeating: 0, count: capacity)
    let result = input.withUnsafeBytes { raw in
        output.withUnsafeMutableBufferPointer { buffer in
            tesseraTmuxRuntimeProjectAuthorityReleasing(
                handle: handle,
                authorityJSON: raw.bindMemory(to: UInt8.self).baseAddress,
                authorityCount: raw.count,
                outputBytes: nullOutput ? nil : buffer.baseAddress,
                outputCapacity: buffer.count
            )
        }
    }
    return (result, result > 0 ? Data(output.prefix(Int(result))) : Data())
}
