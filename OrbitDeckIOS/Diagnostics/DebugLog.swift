import Foundation
import SwiftUI

// ===========================================================================
//  DebugLog.swift — lightweight on-device diagnostic log + viewer
//
//  Writes timestamped (UTC) lines to a rotating file under Application Support/Logs
//  so an operator can capture what happened during a session — a rig that won't
//  connect, an audio route that dropped, a feed that failed — and share the file
//  with the developer. Logging is cheap (a serial queue, off the hot path) and can
//  be turned off. The DebugLogScreen lists the files with Share (email/AirDrop) and
//  a Clear action.
// ===========================================================================

/// Global diagnostic logger. Thread-safe via a private serial queue.
final class ODLog: @unchecked Sendable {
    static let shared = ODLog()

    private let queue = DispatchQueue(label: "org.orbitdeck.debuglog", qos: .utility)
    private let maxBytes = 512 * 1024          // rotate the current file past this size
    private let fileURL: URL
    private let backupURL: URL

    /// Persisted enable flag (defaults on). Users can disable it on the log screen.
    private static let enabledKey = "orbitdeck.debugLog.enabled"
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    static var logsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs", isDirectory: true)
    }

    private init() {
        fileURL = ODLog.logsDir.appendingPathComponent("orbitdeck.log")
        backupURL = ODLog.logsDir.appendingPathComponent("orbitdeck.1.log")
        try? FileManager.default.createDirectory(at: ODLog.logsDir, withIntermediateDirectories: true)
    }

    /// UTC timestamp formatter (created once; used only on the log queue).
    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Append one line. `category` groups related entries (e.g. "cat", "audio", "net").
    func log(_ message: String, category: String = "app") {
        guard isEnabled else { return }
        let when = Date()
        queue.async {
            let line = "\(self.stampFormatter.string(from: when)) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    /// Roll the current file to the single backup slot once it grows too large, so the
    /// log never grows without bound but still keeps recent history.
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }

    /// The existing log files, newest content first.
    func files() -> [URL] {
        [fileURL, backupURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The current file's text (most recent lines last), for the on-screen preview.
    func currentText(maxBytes: Int = 64 * 1024) -> String {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return "" }
        let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
        return String(decoding: slice, as: UTF8.self)
    }

    /// Delete all log files.
    func clear() {
        queue.sync {
            for url in [fileURL, backupURL] { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// MARK: - Viewer

/// Diagnostics screen: shows the recent log, lets the operator share the files
/// (email/AirDrop) with the developer, and clear or disable logging.
struct DebugLogScreen: View {
    @State private var text = ""
    @State private var enabled = ODLog.shared.isEnabled
    @State private var confirmClear = false

    private var files: [URL] { ODLog.shared.files() }

    var body: some View {
        List {
            Section {
                Toggle("Enable diagnostic logging", isOn: $enabled)
                    .onChange(of: enabled) { _, v in ODLog.shared.isEnabled = v }
                Text("Records rig, audio, and network activity to a file on this device. Share it with the developer (n8hm@arrl.net) when reporting a problem. No personal data beyond what you enter for logging is recorded.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section {
                if files.isEmpty {
                    Text("No log entries yet.").foregroundStyle(ODTheme.muted)
                } else {
                    ShareLink(items: files) {
                        Label("Share log files", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear logs", systemImage: "trash")
                    }
                }
            } header: {
                Text("Log files")
            }

            Section("Recent") {
                if text.isEmpty {
                    Text("Empty").foregroundStyle(ODTheme.muted)
                } else {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { text = ODLog.shared.currentText() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { text = ODLog.shared.currentText() }
        .confirmationDialog("Clear all logs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { ODLog.shared.clear(); text = "" }
            Button("Cancel", role: .cancel) {}
        }
    }
}
