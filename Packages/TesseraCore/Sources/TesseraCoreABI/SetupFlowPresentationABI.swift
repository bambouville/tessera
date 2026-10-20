import Foundation
import TesseraCrossDeviceCore

/// Bounded, additive pure projection. This cannot send protocol commands or
/// confer authorization; malformed input fails closed with -1.
@_cdecl("tessera_setup_flow_project_v1")
public func tesseraSetupFlowProjectV1(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let data = SharedABI.requiredData(inputBytes, inputCount, maximum: 262_144),
          let input = try? JSONDecoder().decode(SetupFlowPresentationV1.Input.self, from: data),
          input.hosts.count <= 1_024, (input.selection?.allHostIDs.count ?? 0) <= 1_024,
          let output = try? JSONEncoder().encode(SetupFlowPresentationV1.project(input))
    else { return -1 }
    return SharedABI.copyOut(Array(output), outputBytes, outputCapacity)
}
