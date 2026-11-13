import Foundation

/// 内存日志：界面导出用，同时镜像到 stdout
final class LogStore: ObservableObject {
    static let shared = LogStore()

    private let limit = 2000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let fileHandle: FileHandle?

    @Published private(set) var lines: [String] = []

    private init() {
        let manager = FileManager.default
        let directory = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AtvvMenu", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("atvv.log")
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    /// 追加一行日志，超过上限丢弃最旧的
    func append(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        fflush(stdout)
        if let data = (line + "\n").data(using: .utf8) {
            fileHandle?.write(data)
        }
        if Thread.isMainThread {
            store(line)
        } else {
            DispatchQueue.main.async { self.store(line) }
        }
    }

    private func store(_ line: String) {
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    /// 导出为纯文本
    func exportText() -> String {
        lines.joined(separator: "\n") + "\n"
    }
}

/// 全局日志函数，界面和蓝牙代码共用
func log(_ message: String) {
    LogStore.shared.append(message)
}
