import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    enum State {
        case idle
        case checking
        case current
        case available(String)
        case downloading
        case installing
        case restarting
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?

    private let owner = "hy123-pixel"
    private let repository = "MemoryBar"
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var release: Release?

    var displayVersion: String { currentVersion }

    init() {
        checkForUpdates(presentErrors: false)
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 86_400_000_000_000)
                guard !Task.isCancelled else { break }
                self?.checkForUpdates(presentErrors: false)
            }
        }
    }

    deinit {
        checkTask?.cancel()
        updateTask?.cancel()
        scheduleTask?.cancel()
    }

    func checkForUpdates(presentErrors: Bool = true) {
        guard checkTask == nil, updateTask == nil else { return }
        state = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkTask = nil }
            do {
                let latest = try await self.fetchLatestRelease()
                guard Self.isNewer(latest.version, than: self.currentVersion) else {
                    self.release = nil
                    self.state = .current
                    return
                }
                self.release = latest
                self.state = .available(latest.version)
            } catch {
                let message = "检查更新失败：\(error.localizedDescription)"
                self.state = .failed(message)
                if presentErrors { self.errorMessage = message }
            }
        }
    }

    func downloadAndInstall() {
        guard updateTask == nil, let release else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updateTask = nil }
            do {
                try await self.install(release)
            } catch {
                let message = "更新失败：\(error.localizedDescription)"
                self.state = .failed(message)
                self.errorMessage = message
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func fetchLatestRelease() async throws -> Release {
        let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MemoryBar", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }
        let responseRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !responseRelease.draft, !responseRelease.prerelease,
              let version = Self.normalizedVersion(responseRelease.tagName),
              let archive = responseRelease.assets.first(where: { $0.name == "MemoryBar-\(version)-macOS-universal.zip" }),
              let checksum = responseRelease.assets.first(where: { $0.name == "MemoryBar-\(version)-macOS-universal.zip.sha256" }),
              let archiveURL = URL(string: archive.downloadURL),
              let checksumURL = URL(string: checksum.downloadURL) else {
            throw UpdateError.missingReleaseAssets
        }
        return Release(version: version, archiveURL: archiveURL, checksumURL: checksumURL)
    }

    private func install(_ release: Release) async throws {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.memorybar.app" else {
            throw UpdateError.notRunningFromApp
        }
        let destinationDirectory = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: destinationDirectory.path) else {
            throw UpdateError.installDirectoryNotWritable(destinationDirectory.path)
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        var helperOwnsWorkingDirectory = false
        defer {
            if !helperOwnsWorkingDirectory {
                try? FileManager.default.removeItem(at: workingDirectory)
            }
        }
        let archiveURL = workingDirectory.appendingPathComponent("MemoryBar.zip")
        let extractDirectory = workingDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        state = .downloading
        let (downloadedArchiveURL, archiveResponse) = try await URLSession.shared.download(from: release.archiveURL)
        guard (archiveResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw UpdateError.downloadFailed
        }
        try FileManager.default.moveItem(at: downloadedArchiveURL, to: archiveURL)
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        guard (checksumResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let checksumText = String(data: checksumData, encoding: .utf8),
              let expectedDigest = checksumText.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() else {
            throw UpdateError.checksumDownloadFailed
        }
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let actualDigest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else { throw UpdateError.checksumMismatch }

        try Self.runTool("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDirectory.path])
        let replacementURL = extractDirectory.appendingPathComponent("MemoryBar.app", isDirectory: true)
        guard let replacementBundle = Bundle(url: replacementURL),
              replacementBundle.bundleIdentifier == "com.memorybar.app",
              replacementBundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version,
              FileManager.default.isExecutableFile(atPath: replacementURL.appendingPathComponent("Contents/MacOS/MemoryBar").path) else {
            throw UpdateError.invalidApplicationBundle
        }
        state = .installing
        try launchReplacementHelper(
            replacementAppURL: replacementURL,
            destinationAppURL: appURL,
            workingDirectory: workingDirectory
        )
        helperOwnsWorkingDirectory = true
        state = .restarting
        NSApplication.shared.terminate(nil)
    }

    private func launchReplacementHelper(
        replacementAppURL: URL,
        destinationAppURL: URL,
        workingDirectory: URL
    ) throws {
        let scriptURL = workingDirectory.appendingPathComponent("replace-app.sh")
        try Self.replacementScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            replacementAppURL.path,
            destinationAppURL.path,
            workingDirectory.path
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private static func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.toolFailed(message?.isEmpty == false ? message! : path)
        }
    }

    private static func normalizedVersion(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let components = version.split(separator: ".")
        guard components.count == 3, components.allSatisfy({ Int($0) != nil }) else { return nil }
        return version
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard left.count == 3, right.count == 3 else { return false }
        for index in 0..<3 {
            if left[index] != right[index] { return left[index] > right[index] }
        }
        return false
    }

    private static let replacementScript = """
    #!/bin/sh
    set -eu
    old_pid="$1"
    source_app="$2"
    destination_app="$3"
    working_directory="$4"
    backup_app="${destination_app}.update-backup"

    while /bin/kill -0 "$old_pid" 2>/dev/null; do /bin/sleep 0.2; done
    if [ -e "$backup_app" ]; then /bin/rm -rf "$backup_app"; fi
    if ! /bin/mv "$destination_app" "$backup_app"; then
        /bin/rm -rf "$working_directory"
        /usr/bin/open -a "$destination_app"
        exit 1
    fi
    if ! /usr/bin/ditto "$source_app" "$destination_app"; then
        /bin/rm -rf "$destination_app"
        /bin/mv "$backup_app" "$destination_app"
        /bin/rm -rf "$working_directory"
        /usr/bin/open -a "$destination_app"
        exit 1
    fi
    /bin/rm -rf "$backup_app"
    /usr/bin/open -n "$destination_app"
    /bin/rm -rf "$working_directory"
    """
}

private struct Release {
    let version: String
    let archiveURL: URL
    let checksumURL: URL
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let downloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case missingReleaseAssets
    case notRunningFromApp
    case installDirectoryNotWritable(String)
    case downloadFailed
    case checksumDownloadFailed
    case checksumMismatch
    case invalidApplicationBundle
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub 返回了无效响应。"
        case .missingReleaseAssets: "最新版本缺少应用安装包或 SHA-256 校验文件。"
        case .notRunningFromApp: "请先将内存栏安装到“应用程序”文件夹后再更新。"
        case .installDirectoryNotWritable(let path): "当前应用所在目录不可写：\(path)。请将内存栏移到有写入权限的位置后重试。"
        case .downloadFailed: "安装包下载失败，请检查网络后重试。"
        case .checksumDownloadFailed: "无法下载安装包校验文件。"
        case .checksumMismatch: "安装包校验失败，文件可能已损坏或被篡改。"
        case .invalidApplicationBundle: "安装包中的应用无效或版本不匹配。"
        case .toolFailed(let message): "解压或安装工具执行失败：\(message)"
        }
    }
}
