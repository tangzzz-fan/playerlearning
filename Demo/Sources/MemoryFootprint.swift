import Darwin
import Foundation

/// 读进程的 `phys_footprint`（物理内存占用）。
///
/// 为什么不从外面用 `ps` / `footprint` 量：那些工具在本机会被沙盒挡掉
/// （`/bin/ps` → `operation not permitted`），而**从进程内部读**既不受环境限制，
/// 读到的也正是 Xcode 内存仪表显示的那个值。性能基线要的就是它。
enum MemoryFootprint {
    static func megabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
