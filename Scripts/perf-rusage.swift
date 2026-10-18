// 读取进程的累计 CPU 时间、物理内存占用（phys_footprint，与「活动监视器」的「内存」一列相同）、峰值占用和唤醒次数。
// Scripts/run-perf.py 编译并调用它；每个 PID 输出一行 JSON。
//
//   perf-rusage <pid>...
//
// proc_pid_rusage 的时间单位是 mach 时间刻度，按 mach_timebase_info 换算成纳秒。
import Darwin
import Foundation

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nanoseconds(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }

for argument in CommandLine.arguments.dropFirst() {
    guard let pid = Int32(argument) else { continue }
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    var line: [String: Any] = ["pid": pid, "epoch": Date().timeIntervalSince1970]
    if result == 0 {
        line["cpu_ns"] = nanoseconds(info.ri_user_time) + nanoseconds(info.ri_system_time)
        line["footprint"] = info.ri_phys_footprint
        line["peak_footprint"] = info.ri_lifetime_max_phys_footprint
        line["resident"] = info.ri_resident_size
        line["idle_wakeups"] = info.ri_pkg_idle_wkups
        line["interrupt_wakeups"] = info.ri_interrupt_wkups
        line["instructions"] = info.ri_instructions
    } else {
        line["error"] = String(cString: strerror(errno))
    }
    let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
