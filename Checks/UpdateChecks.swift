import CryptoKit
import Foundation
import MicPriorityCore

func checkUpdates() throws {
    func expect(_ value: Bool) { precondition(value) }
    func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Unsafe update was accepted") } catch {}
    }
    try expect(ReleaseVersion("v0.10.0") > ReleaseVersion("0.9.9"))
    try expect(ReleaseVersion("1.0.0") == ReleaseVersion("v1.0.0"))
    for bad in ["1.2", "1.2.3-beta", "../1.2.3", "1.-2.3", "1..3"] { rejects { _ = try ReleaseVersion(bad) } }
    let hash = String(repeating: "a", count: 64)
    let payload: [String: Any] = [
        "tag_name": "v0.3.0", "html_url": "https://github.com/NotWizard/MicPriority/releases/tag/v0.3.0",
        "draft": false, "prerelease": false,
        "assets": [["name": "MicPriority-0.3.0-macOS-apple-silicon.zip", "size": 123, "state": "uploaded",
                    "digest": "sha256:\(hash)",
                    "browser_download_url": "https://github.com/NotWizard/MicPriority/releases/download/v0.3.0/MicPriority-0.3.0-macOS-apple-silicon.zip"]]
    ]
    func release(_ data: [String: Any]) throws -> UpdateRelease {
        try JSONDecoder().decode(UpdateRelease.self, from: JSONSerialization.data(withJSONObject: data))
    }
    let stable = try release(payload)
    try expect(stable.newer(than: "0.2.1"))
    try expect(!stable.newer(than: "0.3.0"))
    try expect(!stable.newer(than: "0.4.0"))
    _ = try stable.package()
    for key in ["draft", "prerelease"] {
        var altered = payload; altered[key] = true
        try expect(!release(altered).newer(than: "0.2.1"))
        rejects { _ = try release(altered).package() }
    }
    for (key, value) in [("browser_download_url", "https://example.com/update.zip"),
                         ("name", "MicPriority-0.3.0-macOS-intel.zip"), ("digest", "sha256:abc"), ("state", "new")] {
        var altered = payload
        var asset = (payload["assets"] as! [[String: Any]])[0]
        asset[key] = value; altered["assets"] = [asset]
        rejects { _ = try release(altered).package() }
    }
    print("PASS: numeric update versions, stable-only releases, repository, asset and digest boundaries")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MicPriority-update-check-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fm.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("example".utf8).write(to: source.appendingPathComponent("file.txt"))
    let zip = root.appendingPathComponent("safe.zip")
    try AppUpdate.run("/usr/bin/ditto", ["-c", "-k", source.path, zip.path])
    func digest(_ zip: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
    }
    try AppUpdate.verifyArchive(zip, digest: digest(zip))
    rejects { try AppUpdate.verifyArchive(zip, digest: hash) }
    try fm.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: root)
    let linked = root.appendingPathComponent("linked.zip")
    try AppUpdate.run("/usr/bin/ditto", ["-c", "-k", source.path, linked.path])
    rejects { try AppUpdate.verifyArchive(linked, digest: digest(linked)) }
    print("PASS: valid archive, checksum rejection and symlink rejection before extraction")

    if let flag = CommandLine.arguments.firstIndex(of: "--update-bundles") {
        guard CommandLine.arguments.count > flag + 2 else { throw AudioFailure("--update-bundles needs old and new app paths") }
        let old = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        let new = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
        let newVersion = Bundle(url: new)!.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        let target = root.appendingPathComponent("Installed app with spaces.app")
        try AppUpdate.run("/usr/bin/ditto", [old.path, target.path])
        let original = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        let intel = root.appendingPathComponent("Unsupported Intel.app")
        try AppUpdate.run("/usr/bin/ditto", [new.path, intel.path])
        let intelExecutable = intel.appendingPathComponent("Contents/MacOS/MicPriority")
        try fm.removeItem(at: intelExecutable)
        try AppUpdate.run("/usr/bin/lipo", [old.appendingPathComponent("Contents/MacOS/MicPriority").path,
                                           "-thin", "x86_64", "-output", intelExecutable.path])
        try AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", intel.path])
        rejects { try AppUpdate.validate(intel, version: newVersion) }
        print("PASS: native architecture API rejects a validly signed Intel-only app")
        let stage = try AppUpdate.stage(new, target: target, version: newVersion)
        defer { try? fm.removeItem(at: stage) }
        let stagedInfo = stage.appendingPathComponent("MicPriority.app/Contents/Info.plist")
        let goodInfo = try Data(contentsOf: stagedInfo)
        try Data("broken".utf8).write(to: stagedInfo)
        rejects { try AppUpdate.replace(target: target, root: stage, version: newVersion) }
        try expect(Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")) == original)
        try goodInfo.write(to: stagedInfo)
        try AppUpdate.replace(target: target, root: stage, version: newVersion)
        try AppUpdate.validate(target, version: newVersion)
        try expect(Data(contentsOf: stage.appendingPathComponent("previous.app/Contents/Info.plist")) == original)
        rejects { try AppUpdate.replace(target: target, root: stage, version: newVersion) }
        print("PASS: real signed bundle staging, invalid update leaves old app intact, same-volume replacement and backup")
    }
}
