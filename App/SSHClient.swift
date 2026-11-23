import Foundation

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var isSuccess: Bool { status == 0 }
    var errorText: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch status {
        case -1:  return "无法启动 ssh"
        case 255: return "无法连接（网络不可达或 SSH 认证失败）"
        default:  return "ssh 退出码 \(status)"
        }
    }
}

/// 通过系统 ssh 执行远端脚本。复用 ControlMaster，轮询时几乎没有握手开销。
enum SSHClient {
    /// NSHomeDirectory 在沙盒里指向容器；从 passwd 取真实用户目录。
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func run(host: String,
                    script: String,
                    controlDirectory: URL,
                    timeout: TimeInterval = 20) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

                // 沙盒里 HOME 会被指向容器，ssh 需要真实的 ~/.ssh 配置与密钥。
                var environment = ProcessInfo.processInfo.environment
                environment["HOME"] = Self.realHome
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
                process.environment = environment

                let arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "LogLevel=ERROR",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(controlDirectory.path)/%C",
                    "-o", "ControlPersist=120",
                    host, "sh", "-s"
                ]
                process.arguments = arguments

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                if let data = script.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()
                let lock = NSLock()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = data; lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = data; lock.unlock()
                    group.leave()
                }

                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                process.waitUntilExit()
                group.wait()
                watchdog.cancel()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(status: process.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    /// 轻量连通性测试。
    static func test(host: String, controlDirectory: URL) async -> CommandResult {
        let probe = """
        echo "HOSTNAME=$(hostname 2>/dev/null || uname -n)"
        echo "CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
        if command -v nvidia-smi >/dev/null 2>&1; then
          echo "GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
          nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -4
        else
          echo "GPU_COUNT=0"
        fi
        """
        return await run(host: host, script: probe, controlDirectory: controlDirectory, timeout: 15)
    }
}
