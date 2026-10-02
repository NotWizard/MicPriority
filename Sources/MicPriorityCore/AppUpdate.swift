import CryptoKit
import Foundation

public struct ReleaseVersion: Comparable, Sendable {
    public let text: String
    private let parts: [Int]

    public init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil
        }) else { throw AudioFailure("版本号无效：\(text)") }
        self.text = value
        parts = components.map { Int($0)! }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts }
}

public struct UpdateRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int
        public let state: String
        public let digest: String?
        public let url: URL
        enum CodingKeys: String, CodingKey {
            case name, size, state, digest
            case url = "browser_download_url"
        }
    }
    public let tag: String
    public let page: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tag = "tag_name", page = "html_url"
    }

    public func newer(than current: String) throws -> Bool {
        guard !draft, !prerelease else { return false }
        return try ReleaseVersion(tag) > ReleaseVersion(current)
    }

    public func package() throws -> Asset {
        let version = try ReleaseVersion(tag)
        let name = "MicPriority-\(version.text)-macOS-apple-silicon.zip"
        let expectedPage = "https://github.com/NotWizard/MicPriority/releases/tag/\(tag)"
        let expectedDownload = "https://github.com/NotWizard/MicPriority/releases/download/\(tag)/\(name)"
        guard !draft, !prerelease, page.absoluteString == expectedPage,
              let asset = assets.first(where: { $0.name == name && $0.state == "uploaded" }),
              asset.url.absoluteString == expectedDownload,
              (1...100_000_000).contains(asset.size),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.count == 71, digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw AudioFailure("此版本缺少可校验的 Apple Silicon 安装包，请到项目发布页下载。")
        }
        return asset
    }
}

public enum AppUpdate {
    public static let latestURL = URL(string: "https://api.github.com/repos/NotWizard/MicPriority/releases/latest")!
    public static let bundleID = "com.local.MicPriority"

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public static func latest() async throws -> UpdateRelease {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MicPriority", forHTTPHeaderField: "User-Agent")
        let client = session()
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        try check(response)
        guard data.count < 2_000_000 else { throw AudioFailure("发布信息过大，请到项目发布页查看。") }
        return try JSONDecoder().decode(UpdateRelease.self, from: data)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AudioFailure(status == 403 || status == 429 ? "GitHub 请求次数受限，请稍后重试。" :
                status == 404 ? "尚无可下载的正式版本。" : "GitHub 请求失败（\(status)），请检查网络后重试。")
        }
        guard response.url?.scheme == "https" else { throw AudioFailure("下载连接不安全。") }
    }

    public static func prepare(_ release: UpdateRelease) async throws -> URL {
        let asset = try release.package()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MicPriority-download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            let client = session()
            defer { client.invalidateAndCancel() }
            let (temporary, response) = try await client.download(from: asset.url)
            defer { try? fm.removeItem(at: temporary) }
            try check(response)
            let archive = root.appendingPathComponent("update.zip")
            try fm.moveItem(at: temporary, to: archive)
            guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else {
                throw AudioFailure("安装包下载不完整，旧版本未改动。")
            }
            try verifyArchive(archive, digest: String(asset.digest!.dropFirst(7)))
            try Task.checkCancellation()
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
            let version = try ReleaseVersion(release.tag).text
            let nested = extracted.appendingPathComponent("MicPriority-\(version)/MicPriority.app")
            let app = fm.fileExists(atPath: nested.path) ? nested : extracted.appendingPathComponent("MicPriority.app")
            try validate(app, version: version)
            try Task.checkCancellation()
            let prepared = root.appendingPathComponent("MicPriority.app")
            try fm.moveItem(at: app, to: prepared)
            try fm.removeItem(at: archive)
            try fm.removeItem(at: extracted)
            return prepared
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    public static func verifyArchive(_ archive: URL, digest: String) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest.lowercased() else {
            throw AudioFailure("安装包校验失败，旧版本未改动。")
        }
        let names = try run("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
        guard !names.isEmpty, names.count < 10000, names.allSatisfy({ name in
            !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\r") &&
            !name.split(separator: "/").contains("..")
        }) else { throw AudioFailure("安装包包含不安全的路径。") }
        let listing = try run("/usr/bin/zipinfo", ["-l", archive.path]).split(separator: "\n")
        var total = 0
        for row in listing where row.first == "-" || row.first == "d" || row.first == "l" {
            let fields = row.split(whereSeparator: { $0.isWhitespace })
            guard row.first != "l", fields.count >= 4, let size = Int(fields[3]),
                  size >= 0, size < 200_000_000 - total else { throw AudioFailure("安装包内容不安全或过大。") }
            total += size
        }
    }

    public static func validate(_ app: URL, version: String) throws {
        let fm = FileManager.default
        guard app.pathExtension == "app", app.resolvingSymlinksInPath().standardizedFileURL == app.standardizedFileURL,
              let info = try? information(app), info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleExecutable"] as? String == "MicPriority" else {
            throw AudioFailure("安装包的应用身份或版本不匹配。")
        }
        let minimum = info["LSMinimumSystemVersion"] as? String ?? "13.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard minimum.compare(current, options: .numeric) != .orderedDescending else {
            throw AudioFailure("新版需要 macOS \(minimum) 或更新版本。")
        }
        guard let contents = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw AudioFailure("无法检查更新应用。")
        }
        for case let entry as URL in contents {
            guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw AudioFailure("更新应用包含不支持的符号链接。")
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let executable = app.appendingPathComponent("Contents/MacOS/MicPriority")
        guard try run("/usr/bin/lipo", [executable.path, "-archs"]).split(whereSeparator: { $0.isWhitespace }).contains("arm64") else {
            throw AudioFailure("此安装包不支持 Apple Silicon。")
        }
    }

    // Stage alongside the destination so both replacement and rollback are same-volume renames.
    public static func stage(_ prepared: URL, target: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let target = target.standardizedFileURL
        guard target.pathExtension == "app", fm.fileExists(atPath: target.path),
              target.resolvingSymlinksInPath() == target,
              (try? information(target)["CFBundleIdentifier"] as? String) == bundleID,
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: target.path) else {
            throw AudioFailure("当前应用位置无法直接更新。请先将应用移到可写的“应用程序”目录，再打开并重试。")
        }
        let root = target.deletingLastPathComponent().appendingPathComponent(".MicPriority-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let staged = root.appendingPathComponent("MicPriority.app")
            try run("/usr/bin/ditto", [prepared.path, staged.path])
            try validate(staged, version: version)
            let installer = root.appendingPathComponent("installer")
            try fm.copyItem(at: target.appendingPathComponent("Contents/MacOS/MicPriority"), to: installer)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.path)
            return root
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    public static func replace(target: URL, root: URL, version: String) throws {
        let fm = FileManager.default
        let target = target.standardizedFileURL
        let root = root.standardizedFileURL
        guard root.deletingLastPathComponent() == target.deletingLastPathComponent(),
              root.lastPathComponent.hasPrefix(".MicPriority-update-"),
              root.resolvingSymlinksInPath() == root, target.resolvingSymlinksInPath() == target,
              (try? information(target)["CFBundleIdentifier"] as? String) == bundleID else {
            throw AudioFailure("更新位置无效。")
        }
        let staged = root.appendingPathComponent("MicPriority.app")
        let backup = root.appendingPathComponent("previous.app")
        try validate(staged, version: version)
        guard let oldVersion = try information(target)["CFBundleShortVersionString"] as? String,
              try ReleaseVersion(version) > ReleaseVersion(oldVersion) else { throw AudioFailure("更新版本必须高于当前版本。") }
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
            try validate(target, version: version)
        } catch {
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: staged) }
            try fm.moveItem(at: backup, to: target)
            throw error
        }
    }

    private static func information(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AudioFailure("应用信息无效。")
        }
        return info
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioFailure("\(URL(fileURLWithPath: executable).lastPathComponent) 检查或操作失败。")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
