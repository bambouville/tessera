import Foundation

/// Millisecond arithmetic for the authority session, the show tracker and
/// their helpers. Times reach them from platform clocks, on Android through
/// the JSON ABI, so an extreme value must clamp: an overflow trap through JNI
/// kills the whole app process, and a wrapped deadline lands in the past
/// (firing at once) or the far future (never firing).
extension Int64 {
    /// `self + other`, clamped to the representable range.
    @inline(__always)
    func clampedAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }

    /// `self - other`, clamped to the representable range.
    @inline(__always)
    func clampedSubtracting(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        guard overflow else { return difference }
        return other < 0 ? .max : .min
    }

    /// `self * other`, clamped to the representable range.
    @inline(__always)
    func clampedMultiplying(by other: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return product }
        return (self < 0) == (other < 0) ? .max : .min
    }
}
