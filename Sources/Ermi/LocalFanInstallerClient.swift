import Foundation

enum LocalFanInstallerError: LocalizedError {
    case cancelled
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消管理员验证。"
        case .failed(let message): message
        }
    }
}

enum LocalFanInstallerClient {
    static func run(uninstall: Bool) async throws {
        let name = uninstall ? "UninstallLocalFanControl" : "InstallLocalFanControl"
        guard let url = Bundle.main.url(forResource: name, withExtension: "command") else {
            throw LocalFanInstallerError.failed("找不到本机安装入口，请运行打包后的 Ermi.app。")
        }
        // Process 与管道等待都在后台，系统授权弹窗等待用户时不会阻塞 MainActor。
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [url.path, "--gui"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try validateResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    static func validateResult(status: Int32, output: String) throws {
        // 取消使用固定标记，避免依赖操作系统语言或把用户取消显示为安装错误。
        if status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines) == "ERMI_AUTH_CANCELLED" {
            throw LocalFanInstallerError.cancelled
        }
        guard status == 0 else {
            throw LocalFanInstallerError.failed(output.isEmpty ? "安装程序退出（\(status)）。" : output)
        }
    }
}
