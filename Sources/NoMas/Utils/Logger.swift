import Foundation
import AppKit

/// Simple file-based logger for debugging
class Logger {
    static let shared = Logger()
    
    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.nomas.logger", qos: .utility)
    
    private init() {
        // Create log file in Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("NoMas", isDirectory: true)
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        
        logFileURL = appDirectory.appendingPathComponent("nomas.log")
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        // Add startup marker
        log("========================================")
        log("No Mas! started")
        log("========================================")
    }
    
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"
        
        // Print to console
        print(logMessage, terminator: "")
        
        // Write to file
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if let data = logMessage.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: self.logFileURL) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: self.logFileURL)
                }
            }
            
            // Rotate log if too large (> 1MB)
            self.rotateLogIfNeeded()
        }
    }
    
    private func rotateLogIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize > 1_000_000 else {
            return
        }
        
        // Archive old log
        let archiveURL = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.moveItem(at: logFileURL, to: archiveURL)
    }
    
    func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
    
    func getLogContents() -> String {
        return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "No logs available"
    }
    
    func clearLogs() {
        try? FileManager.default.removeItem(at: logFileURL)
        log("Logs cleared")
    }
}
