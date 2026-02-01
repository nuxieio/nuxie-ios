import Foundation

actor FontStore {

    private let cacheDirectory: URL
    private var entriesById: [String: FontManifestEntry] = [:]
    private var pendingDownloads: [String: Task<URL?, Error>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("nuxie_fonts")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        LogDebug("FontStore initialized at: \(cacheDirectory.path)")
    }

    func registerFonts(_ entries: [FontManifestEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            entriesById[entry.id] = entry
        }
    }

    func registerManifest(_ manifest: FontManifest?) {
        guard let manifest else { return }
        registerFonts(manifest.fonts)
    }

    func prefetchFonts(_ entries: [FontManifestEntry]) async {
        guard !entries.isEmpty else { return }
        registerFonts(entries)
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { [weak self] in
                    guard let self else { return }
                    _ = await self.fetchFontIfNeeded(entry)
                }
            }
        }
    }

    func fontPayload(for id: String) async -> (data: Data, mimeType: String)? {
        guard let entry = entriesById[id] else {
            return nil
        }
        let mimeType = resolveMimeType(format: entry.format)
        if let cached = cachedURL(for: entry), let data = try? Data(contentsOf: cached) {
            return (data, mimeType)
        }
        if let fetched = await fetchFontIfNeeded(entry),
           let data = try? Data(contentsOf: fetched) {
            return (data, mimeType)
        }
        return nil
    }

    func fontData(for id: String) async -> Data? {
        return await fontPayload(for: id)?.data
    }

    func clearCache() {
        do {
            try FileManager.default.removeItem(at: cacheDirectory)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            entriesById.removeAll()
            pendingDownloads.removeAll()
            LogInfo("Cleared font cache")
        } catch {
            LogError("Failed to clear font cache: \(error)")
        }
    }

    private func cachedURL(for entry: FontManifestEntry) -> URL? {
        let url = fileURL(for: entry)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func fileURL(for entry: FontManifestEntry) -> URL {
        let hash = entry.contentHash.replacingOccurrences(of: "sha256:", with: "")
        let ext = entry.format.isEmpty ? "woff2" : entry.format
        return cacheDirectory.appendingPathComponent("\(hash).\(ext)")
    }

    private func resolveMimeType(format: String) -> String {
        let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "woff2":
            return "font/woff2"
        case "woff":
            return "font/woff"
        case "ttf", "truetype":
            return "font/ttf"
        case "otf", "opentype":
            return "font/otf"
        default:
            return "application/octet-stream"
        }
    }

    private func fetchFontIfNeeded(_ entry: FontManifestEntry) async -> URL? {
        if let cached = cachedURL(for: entry) {
            return cached
        }

        let hashKey = entry.contentHash.replacingOccurrences(of: "sha256:", with: "")
        if let pending = pendingDownloads[hashKey] {
            return try? await pending.value
        }

        let task = Task<URL?, Error> { [cacheDirectory] in
            guard let url = URL(string: entry.assetUrl) else {
                return nil
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "NuxieFontStore",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Font download failed"]
                )
            }
            let ext = entry.format.isEmpty ? "woff2" : entry.format
            let target = cacheDirectory.appendingPathComponent("\(hashKey).\(ext)")
            try data.write(to: target, options: [.atomic])
            return target
        }

        pendingDownloads[hashKey] = task
        defer { pendingDownloads[hashKey] = nil }

        do {
            return try await task.value
        } catch {
            LogWarning("Font download failed for \(entry.family) \(entry.weight): \(error)")
            return nil
        }
    }
}
