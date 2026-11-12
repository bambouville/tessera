// Tessera/DeviceStackGuard.swift
// Gives the simulator's main thread a device-sized stack, with a margin.
import Darwin
import Foundation

/// The simulator runs the main thread on a macOS stack of 8 MB; an iOS device
/// gives it 1 MB, 1008 KB of it usable. A view whose first render needs more
/// than that passes every simulator run and crashes every device launch, as
/// the root shell and the session views once did: unoptimized code keeps a
/// copy of a long modifier chain's growing value per link in the getter's
/// frame (see `View.stackBoundary()`).
///
/// DEBUG simulator builds therefore fence the main stack `limitKB` below its
/// top, a quarter short of a device, so a render that comes near the device's
/// limit faults here first. Hosted unit tests, UI tests, harnesses and the
/// integration lanes all inherit it. A render past the fence stops with
/// `EXC_BAD_ACCESS` inside the logged `main-stack-guard` page.
/// `TESSERA_MAIN_STACK_LIMIT_KB` moves the fence; `0` removes it.
@MainActor
enum DeviceStackGuard {
    static let defaultLimitKB = 768

    /// The first byte of the fenced page, once installed.
    private(set) static var guardAddress: UInt?

    /// Call first thing at launch, on the main thread.
    static func install() {
        #if DEBUG && targetEnvironment(simulator)
        guard guardAddress == nil, pthread_main_np() != 0 else { return }
        let limitKB = ProcessInfo.processInfo.environment["TESSERA_MAIN_STACK_LIMIT_KB"]
            .flatMap(Int.init) ?? defaultLimitKB
        guard limitKB > 0 else { return }
        let thread = pthread_self()
        // Darwin reports a stack's highest address; it grows down from there.
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        let page = UInt(getpagesize())
        let limit = UInt(limitKB) * 1024
        guard limit + page < size else { return }
        let start = ((top - limit) & ~(page - 1)) - page
        guard mprotect(UnsafeMutableRawPointer(bitPattern: start), Int(page), PROT_NONE) == 0 else {
            NSLog("main-stack-guard failed errno=%d", errno)
            return
        }
        guardAddress = start
        NSLog("main-stack-guard limit=%dKB page=0x%lx-0x%lx", limitKB, start, start + page)
        #endif
    }
}
