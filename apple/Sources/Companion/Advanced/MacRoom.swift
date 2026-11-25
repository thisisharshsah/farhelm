import CompanionBoard
import Darwin
import Foundation

/// The Mac's load and free memory, measured now, for the app's limit on
/// runs at once (`RunLimit`).
enum MacRoom {
    static func now() -> RunLimit.Mac {
        var loads = [Double](repeating: 0, count: 3)
        let load = getloadavg(&loads, 3) > 0 ? loads[0] : 0
        return RunLimit.Mac(cores: ProcessInfo.processInfo.activeProcessorCount, load: load,
                            freeMemory: freeMemory())
    }

    /// Memory that can be had without swapping: free pages, and pages
    /// macOS gives back at once when asked (inactive, purgeable,
    /// speculative). Half the Mac's memory when it cannot be read, so a
    /// failed reading neither floods the Mac nor stops all work.
    private static func freeMemory() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return ProcessInfo.processInfo.physicalMemory / 2 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return pages * UInt64(getpagesize())
    }
}