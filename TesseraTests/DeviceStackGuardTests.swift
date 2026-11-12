import Darwin
import XCTest
@testable import Tessera

/// The test host launched the app, so these check the fence its launch put on
/// the main stack. Every hosted test then renders within a device's budget.
final class DeviceStackGuardTests: XCTestCase {
    @MainActor
    func test_launchFencesTheMainStackShortOfADevice() throws {
        #if targetEnvironment(simulator)
        let start = try XCTUnwrap(DeviceStackGuard.guardAddress)
        let page = UInt(getpagesize())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        XCTAssertEqual(top - (start + page), UInt(DeviceStackGuard.defaultLimitKB) * 1024)
        // A device's main thread has 1008 KB usable.
        XCTAssertLessThan(DeviceStackGuard.defaultLimitKB, 1008)

        var address = vm_address_t(start)
        var size: vm_size_t = 0
        var info = vm_region_basic_info_data_64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size
        )
        var object: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        XCTAssertEqual(UInt(address), start)
        XCTAssertEqual(info.protection, VM_PROT_NONE)
        #endif
    }
}
