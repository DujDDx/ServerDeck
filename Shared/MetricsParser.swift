import Foundation

/// 在远端执行的一段纯 POSIX shell 脚本：一次连接取回 GPU / CPU / 每核 / 内存 / 负载。
/// CPU 使用率在远端做两次采样（间隔 0.4s）计算，避免本地维护状态。
enum RemoteMetrics {
    static let script: String = #"""
export LC_ALL=C
echo "##HOST"
hostname 2>/dev/null || uname -n
echo "##CORES"
nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0
T1=$(mktemp 2>/dev/null || echo /tmp/.sd_cpu1.$$)
T2=$(mktemp 2>/dev/null || echo /tmp/.sd_cpu2.$$)
awk '/^cpu[0-9]+ /' /proc/stat > "$T1" 2>/dev/null
read -r _cpu u1 n1 s1 i1 w1 irq1 sirq1 st1 _rest < /proc/stat
sleep 0.4
read -r _cpu u2 n2 s2 i2 w2 irq2 sirq2 st2 _rest < /proc/stat
awk '/^cpu[0-9]+ /' /proc/stat > "$T2" 2>/dev/null
echo "##CPU"
echo "$(( (u2-u1)+(n2-n1)+(s2-s1)+(i2-i1)+(w2-w1)+(irq2-irq1)+(sirq2-sirq1)+(st2-st1) )) $((i2-i1)) $((w2-w1))"
echo "##CPUD"
echo "$((u2-u1)) $((n2-n1)) $((s2-s1)) $((i2-i1)) $((w2-w1)) $((irq2-irq1)) $((sirq2-sirq1)) $((st2-st1))"
echo "##CORE"
awk 'NR==FNR{a[$1]=$2+$3+$4+$5+$6+$7+$8+$9; ai[$1]=$5; next} {t=$2+$3+$4+$5+$6+$7+$8+$9; d=t-a[$1]; di=$5-ai[$1]; if (d>0) printf "%d %.4f\n", substr($1,4)+0, (d-di)/d}' "$T1" "$T2" 2>/dev/null
rm -f "$T1" "$T2"
echo "##MEM"
awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} /^SReclaimable:/{sr=$2} END{print t+0, a+0, f+0, b+0, c+0, sr+0}' /proc/meminfo
echo "##LOAD"
cut -d' ' -f1-3 /proc/loadavg
echo "##UP"
cut -d' ' -f1 /proc/uptime
echo "##GPU"
NSMI=""
if command -v nvidia-smi >/dev/null 2>&1; then NSMI=$(command -v nvidia-smi); fi
if [ -z "$NSMI" ] && [ -x /usr/bin/nvidia-smi ]; then NSMI=/usr/bin/nvidia-smi; fi
if [ -z "$NSMI" ] && [ -x /usr/local/bin/nvidia-smi ]; then NSMI=/usr/local/bin/nvidia-smi; fi
if [ -n "$NSMI" ]; then
  "$NSMI" --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null
fi
echo "##GPUAPPS"
if [ -n "$NSMI" ]; then
  "$NSMI" --query-compute-apps=pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null | head -20
fi
echo "##END"
"""#
}

enum MetricsParser {
    static func parse(output: String,
                      id: UUID,
                      name: String,
                      host: String,
                      now: Date = Date()) -> HostSnapshot {
        var hostname: String?
        var cores = 0
        var cpuTotal: Double = 0
        var cpuIdle: Double = 0
        var cpuDeltas: [Double] = []
        var coreValues: [(Int, Double)] = []
        var memTotalKB: Double = 0
        var memAvailKB: Double = 0
        var memFreeKB: Double = 0
        var memBuffersKB: Double = 0
        var memCachedKB: Double = 0
        var memSReclaimKB: Double = 0
        var load: [Double] = []
        var uptime: Double = 0
        var gpus: [GPUMetric] = []
        var processes: [GPUProcess] = []
        var sawEnd = false

        var section = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("##") {
                section = String(line.dropFirst(2))
                if section == "END" { sawEnd = true }
                continue
            }

            switch section {
            case "HOST":
                if hostname == nil { hostname = line }

            case "CORES":
                cores = Int(line) ?? 0

            case "CPU":
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 2 {
                    cpuTotal = parts[0]
                    cpuIdle = parts[1]
                }

            case "CPUD":
                cpuDeltas = line.split(separator: " ").compactMap { Double($0) }

            case "CORE":
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 2 {
                    coreValues.append((Int(parts[0]), min(1, max(0, parts[1]))))
                }

            case "MEM":
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 2 {
                    memTotalKB = parts[0]
                    memAvailKB = parts[1]
                }
                if parts.count >= 6 {
                    memFreeKB = parts[2]
                    memBuffersKB = parts[3]
                    memCachedKB = parts[4]
                    memSReclaimKB = parts[5]
                }

            case "LOAD":
                load = line.split(separator: " ").compactMap { Double($0) }

            case "UP":
                uptime = Double(line) ?? 0

            case "GPU":
                if let gpu = parseGPU(line) { gpus.append(gpu) }

            case "GPUAPPS":
                if let proc = parseProcess(line) { processes.append(proc) }

            default:
                break
            }
        }

        let cpuUsage = cpuTotal > 0 ? min(1, max(0, (cpuTotal - cpuIdle) / cpuTotal)) : 0
        let memTotal = memTotalKB * 1024
        let memUsed = max(0, (memTotalKB - memAvailKB) * 1024)

        var cpuUser: Double?
        var cpuSystem: Double?
        var cpuIO: Double?
        var cpuSteal: Double?
        if cpuTotal > 0, cpuDeltas.count >= 8 {
            cpuUser = (cpuDeltas[0] + cpuDeltas[1]) / cpuTotal
            cpuSystem = (cpuDeltas[2] + cpuDeltas[5] + cpuDeltas[6]) / cpuTotal
            cpuIO = cpuDeltas[4] / cpuTotal
            cpuSteal = cpuDeltas[7] / cpuTotal
        }

        let coreUsages = coreValues.sorted { $0.0 < $1.0 }.map(\.1)
        if cores == 0 { cores = coreUsages.count }

        // 同一进程可能出现在多张卡上，按 PID 合并显存占用。
        var merged: [Int: GPUProcess] = [:]
        for process in processes {
            if var existing = merged[process.pid] {
                existing.memoryMB += process.memoryMB
                merged[process.pid] = existing
            } else {
                merged[process.pid] = process
            }
        }
        let mergedProcesses = merged.values.sorted { $0.memoryMB > $1.memoryMB }

        var snapshot = HostSnapshot(
            id: id, name: name, host: host, timestamp: now, online: sawEnd, error: nil,
            hostname: hostname, coreCount: cores, gpus: gpus.sorted { $0.index < $1.index },
            gpuProcesses: mergedProcesses,
            cpuUsage: cpuUsage, memUsedBytes: memUsed, memTotalBytes: memTotal,
            load1: load.count > 0 ? load[0] : 0,
            load5: load.count > 1 ? load[1] : 0,
            load15: load.count > 2 ? load[2] : 0,
            uptime: uptime,
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            cpuIO: cpuIO,
            cpuSteal: cpuSteal,
            coreUsages: coreUsages.isEmpty ? nil : coreUsages,
            memFreeBytes: memFreeKB * 1024,
            memCachedBytes: (memBuffersKB + memCachedKB + memSReclaimKB) * 1024
        )
        if !sawEnd {
            snapshot.error = "远端脚本未完整返回"
        }
        return snapshot
    }

    // "0, Tesla V100-SXM2-16GB, 93, 16042, 16384, 57, 278.69, 300.00"
    private static func parseGPU(_ line: String) -> GPUMetric? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 5, let index = Int(fields[0]) else { return nil }
        return GPUMetric(
            index: index,
            name: fields[1].isEmpty ? "GPU \(index)" : fields[1],
            utilization: number(fields[2]) ?? 0,
            memoryUsedMB: number(fields[3]) ?? 0,
            memoryTotalMB: number(fields[4]) ?? 0,
            temperature: fields.count > 5 ? number(fields[5]) : nil,
            powerDraw: fields.count > 6 ? number(fields[6]) : nil,
            powerLimit: fields.count > 7 ? number(fields[7]) : nil
        )
    }

    // "984552, 15900, /path/to/python"
    private static func parseProcess(_ line: String) -> GPUProcess? {
        let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2, let pid = Int(fields[0]) else { return nil }
        let name = fields.count > 2 ? fields[2] : "未知进程"
        return GPUProcess(pid: pid, memoryMB: number(fields[1]) ?? 0, name: name)
    }

    /// 处理 "[N/A]"、"[Not Supported]" 等。
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("["), trimmed != "N/A" else { return nil }
        return Double(trimmed)
    }
}
