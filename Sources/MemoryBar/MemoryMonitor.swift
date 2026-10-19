import AppKit
import Darwin
import Foundation
import SwiftUI

struct MemoryItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    let bytes: UInt64
    let icon: NSImage
    let appURL: URL?
    let processIDs: [pid_t]
}

struct MemorySnapshot {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let items: [MemoryItem]
    let sampledAt: Date

    var applications: [MemoryItem] { items.filter { $0.appURL != nil } }
    var backgroundProcesses: [MemoryItem] { items.filter { $0.appURL == nil } }

    static let empty = MemorySnapshot(totalBytes: ProcessInfo.processInfo.physicalMemory, usedBytes: 0, items: [], sampledAt: .now)
}

private struct RawMemoryItem: Sendable {
    let id: String
    let name: String
    let detail: String
    let bytes: UInt64
    let appPath: String?
    let processIDs: [pid_t]
}

private struct RawMemorySnapshot: Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let items: [RawMemoryItem]
    let sampledAt: Date
}

private struct ActiveApplication: Sendable {
    let bundlePath: String
    let localizedName: String
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot = MemorySnapshot.empty
    @Published private(set) var isRefreshing = false

    private var refreshTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]

    var statusBarMemory: String {
        shortMemory(snapshot.usedBytes)
    }

    init() {
        refresh()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let activeApplications = NSWorkspace.shared.runningApplications.compactMap { application -> ActiveApplication? in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  let bundleURL = application.bundleURL,
                  let localizedName = application.localizedName else { return nil }
            return ActiveApplication(
                bundlePath: bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
                localizedName: localizedName
            )
        }
        Task { [weak self] in
            let rawSnapshot = await Task.detached(priority: .utility) {
                ProcessMemoryCollector.collectSnapshot(activeApplications: activeApplications)
            }.value
            guard let self else { return }
            self.snapshot = self.makeSnapshot(rawSnapshot)
            self.isRefreshing = false
        }
    }

    func terminate(_ item: MemoryItem) {
        if let appURL = item.appURL {
            let appPath = appURL.standardizedFileURL.path
            let runningApp = NSWorkspace.shared.runningApplications.first { application in
                application.bundleURL?.standardizedFileURL.path == appPath
                    && item.processIDs.contains(application.processIdentifier)
            }
            if runningApp?.forceTerminate() == true { return }
        }

        for pid in item.processIDs {
            _ = kill(pid, SIGTERM)
        }
    }

    private func makeSnapshot(_ rawSnapshot: RawMemorySnapshot) -> MemorySnapshot {
        let minimumApplicationMemory: UInt64 = 64 * 1_048_576
        let items = rawSnapshot.items.compactMap { item -> MemoryItem? in
            let appURL = item.appPath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL
            }
            if appURL != nil && item.bytes < minimumApplicationMemory { return nil }

            let cacheKey = item.appPath ?? "process:\(item.name)"
            let icon: NSImage
            if let cachedIcon = iconCache[cacheKey] {
                icon = cachedIcon
            } else if let appPath = item.appPath {
                let appBundlePath = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL.path
                let ownBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
                if appBundlePath == ownBundlePath,
                   let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let ownIcon = NSImage(contentsOf: iconURL) {
                    icon = ownIcon
                } else {
                    icon = NSWorkspace.shared.icon(forFile: appPath)
                }
                iconCache[cacheKey] = icon
            } else {
                icon = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
                iconCache[cacheKey] = icon
            }

            return MemoryItem(
                id: item.id,
                name: item.name,
                detail: item.detail,
                bytes: item.bytes,
                icon: icon,
                    appURL: appURL,
                    processIDs: item.processIDs
            )
        }
        return MemorySnapshot(
            totalBytes: rawSnapshot.totalBytes,
            usedBytes: rawSnapshot.usedBytes,
            items: items,
            sampledAt: rawSnapshot.sampledAt
        )
    }

    static func formattedMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private func shortMemory(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private enum ProcessMemoryCollector {
    static func collectSnapshot(activeApplications: [ActiveApplication]) -> RawMemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        let pids = allProcessIDs()
        var groups: [String: ProcessGroup] = [:]
        let activeAppsByBundlePath = Dictionary(
            activeApplications.map { ($0.bundlePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for pid in pids where pid > 0 {
            guard let usage = physicalFootprint(pid: pid), usage > 0,
                  let path = processPath(pid: pid) else { continue }

            let executableURL = URL(fileURLWithPath: path)
            let appBundlePath = activeApplicationBundlePath(for: executableURL, activeApps: activeAppsByBundlePath)
            let nestedAppURL = containingAppURL(for: executableURL)
            if appBundlePath == nil && nestedAppURL != nil { continue }
            if appBundlePath == nil && isAppleSystemProcess(executableURL) { continue }
            let key: String
            let name: String
            let detail: String

            if let appBundlePath {
                key = "app:\(appBundlePath)"
                name = activeAppsByBundlePath[appBundlePath]?.localizedName ?? URL(fileURLWithPath: appBundlePath).deletingPathExtension().lastPathComponent
                detail = URL(fileURLWithPath: appBundlePath).lastPathComponent
            } else {
                let processName = executableURL.lastPathComponent.isEmpty ? "未知进程" : executableURL.lastPathComponent
                key = "process:\(pid)"
                name = processName
                detail = "PID \(pid)"
            }

            var group = groups[key] ?? ProcessGroup(
                id: key,
                name: name,
                detail: detail,
                appPath: appBundlePath,
                bytes: 0,
                processIDs: []
            )
            group.bytes += usage
            group.processIDs.append(pid)
            groups[key] = group
        }

        let items = groups.values
            .map { group in
                RawMemoryItem(
                    id: group.id,
                    name: group.name,
                    detail: group.detail,
                    bytes: group.bytes,
                    appPath: group.appPath,
                    processIDs: group.processIDs
                )
            }
            .sorted { $0.bytes > $1.bytes }

        return RawMemorySnapshot(
            totalBytes: total,
            usedBytes: systemMemoryInUse(totalBytes: total),
            items: items,
            sampledAt: .now
        )
    }

    private static func allProcessIDs() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(requiredBytes) / MemoryLayout<pid_t>.size + 32)
        let resultBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard resultBytes > 0 else { return [] }
        return Array(pids.prefix(Int(resultBytes) / MemoryLayout<pid_t>.size))
    }

    private static func physicalFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private static func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func containingAppURL(for executableURL: URL) -> URL? {
        var candidate = executableURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func activeApplicationBundlePath(
        for executableURL: URL,
        activeApps: [String: ActiveApplication]
    ) -> String? {
        var candidate = executableURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                let bundlePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                if activeApps[bundlePath] != nil { return bundlePath }
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func isAppleSystemProcess(_ executableURL: URL) -> Bool {
        let path = executableURL.standardizedFileURL.path
        let systemRoots = [
            "/System/Library/",
            "/System/Cryptexes/",
            "/usr/libexec/",
            "/usr/sbin/",
            "/usr/bin/",
            "/sbin/",
            "/bin/",
            "/private/var/db/"
        ]
        return systemRoots.contains { path.hasPrefix($0) }
    }

    private static func systemMemoryInUse(totalBytes: UInt64) -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_page_size)
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        return min(totalBytes, usedPages * pageSize)
    }

}

private struct ProcessGroup {
    let id: String
    let name: String
    let detail: String
    let appPath: String?
    var bytes: UInt64
    var processIDs: [pid_t]
}
