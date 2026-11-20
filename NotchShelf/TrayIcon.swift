import AppKit

/// Load the owner's small menu artwork, including template assets in asset catalogs.
enum TrayIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for app: NSRunningApplication, identifier: String? = nil) -> NSImage? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        let key = "\(url.path)/\(identifier ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var resources = bundle
        var names = [String]()
        switch app.bundleIdentifier {
        case "com.linguee.DeepLCopyTranslator":
            if let nested = bundle.url(forResource: "App_Assets", withExtension: "bundle"),
               let assets = Bundle(url: nested) { resources = assets }
            names = ["StatusItem"]
        case "org.pqrs.Karabiner-Console-User-Server": names = ["menu"]
        case "com.openai.codex": names = ["chatgptTemplate"]
        case "com.binarynights.ForkLiftMini": names = ["ForkLiftTemplate"]
        case "com.electron.ollama": names = ["ollamaDark", "ollama"]
        default: break
        }
        if let identifier { names.insert(identifier, at: 0) }
        names += ["TrayIconTemplate", "MenuBarIcon", "StatusBarIcon", "StatusItem", "MenuIcon", "TrayIcon"]
        var image = names.lazy.compactMap { resources.image(forResource: NSImage.Name($0)) }.first
        if image == nil, app.bundleIdentifier == "com.electron.dockerdesktop",
           let archive = bundle.url(forResource: "app", withExtension: "asar") {
            image = dockerTray(in: archive)
        }
        guard let result = image?.copy() as? NSImage else { return nil }
        result.isTemplate = true
        cache.setObject(result, forKey: key)
        return result
    }

    // Electron stores Docker's menu template inside its read-only ASAR archive.
    // Read only the header and the requested PNG, never the entire archive.
    private static func dockerTray(in url: URL) -> NSImage? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let prefix = try? file.read(upToCount: 16), prefix.count == 16 else { return nil }
        func number(_ offset: Int) -> Int {
            Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
        let headerSize = number(12)
        guard headerSize > 0, headerSize < 32 * 1024 * 1024, headerSize <= number(4),
              let header = try? file.read(upToCount: headerSize), header.count == headerSize,
              var entry = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else { return nil }
        for part in ["assets", "tray", "darwin", "statusItemIcon-0Template@2x.png"] {
            guard let children = entry["files"] as? [String: Any], let child = children[part] as? [String: Any] else { return nil }
            entry = child
        }
        guard let raw = entry["offset"] as? String, let offset = UInt64(raw),
              let size = entry["size"] as? Int, (1...1_048_576).contains(size),
              offset <= UInt64.max - UInt64(8 + number(4)),
              (try? file.seek(toOffset: UInt64(8 + number(4)) + offset)) != nil,
              let data = try? file.read(upToCount: size), data.count == size else { return nil }
        return NSImage(data: data)
    }
}
