import Foundation

/// Top-level WebArchive orchestrator that manages storage and coordinates with WebArchiver
actor FlowArchiver {
    
    // MARK: - Properties
    
    private let webArchiver: WebArchiver
    private let cacheDirectory: URL
    
    // MARK: - Initialization
    
    init(webArchiver: WebArchiver? = nil) {
        // Define canonical storage location for web archives
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("nuxie_flows")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Initialize WebArchiver (use provided or create default)
        self.webArchiver = webArchiver ?? WebArchiver()
        
        LogDebug("FlowArchiver initialized with cache at: \(cacheDirectory.path)")
    }
    
    // MARK: - Public API
    
    /// Preload a web archive for a flow - downloads and caches
    func preloadArchive(for flow: RemoteFlow) async {
        LogDebug("Preloading archive for flow: \(flow.id)")
        
        guard let baseURL = URL(string: flow.url) else {
            LogError("Invalid URL for flow: \(flow.id)")
            return
        }
        
        do {
            let archiveData = try await webArchiver.downloadAndBuildArchive(
                manifest: flow.manifest,
                baseURL: baseURL
            )
            
            // Store at canonical location
            let archiveURL = canonicalURL(for: flow)
            try archiveData.write(to: archiveURL)
            LogDebug("Cached web archive for flow \(flow.id) at: \(archiveURL.path)")
        } catch {
            LogError("Failed to preload archive for flow \(flow.id): \(error)")
        }
    }
    
    /// Get the file URL for a cached web archive
    func getArchiveURL(for flow: RemoteFlow) -> URL? {
        let archiveURL = canonicalURL(for: flow)
        
        // Check if exists
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            LogDebug("Found cached archive for flow \(flow.id)")
            return archiveURL
        }
        
        LogDebug("No cached archive for flow \(flow.id)")
        return nil
    }
    
    /// Get cached archive URL by flow ID (synchronous helper)
    func getCachedArchiveURL(for flowId: String) -> URL? {
        // Find any archive for this flow ID
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            )
            
            for url in contents where url.lastPathComponent.contains(flowId) {
                LogDebug("Found cached archive for flow \(flowId)")
                return url
            }
        } catch {
            LogError("Failed to check archive for flow \(flowId): \(error)")
        }
        
        LogDebug("No cached archive for flow \(flowId)")
        return nil
    }
    
    /// Get or download web archive
    func getOrDownloadArchive(for flow: RemoteFlow) async throws -> URL {
        // Check if already cached
        if let cachedURL = getArchiveURL(for: flow) {
            LogDebug("Returning cached archive for flow \(flow.id)")
            return cachedURL
        }
        
        guard let baseURL = URL(string: flow.url) else {
            throw FlowError.invalidManifest
        }
        
        LogInfo("Downloading archive for flow \(flow.id)")
        
        // Download and build
        let archiveData = try await webArchiver.downloadAndBuildArchive(
            manifest: flow.manifest,
            baseURL: baseURL
        )
        
        let archiveURL = canonicalURL(for: flow)
        try archiveData.write(to: archiveURL)
        LogDebug("Downloaded and cached archive for flow \(flow.id)")
        return archiveURL
    }
    
    /// Remove a specific flow's archive
    func removeArchive(for flowId: String) {
        // Find and remove any archives for this flow ID
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            )
            
            for url in contents where url.lastPathComponent.contains(flowId) {
                try? FileManager.default.removeItem(at: url)
                LogDebug("Removed archive for flow \(flowId)")
            }
        } catch {
            LogError("Failed to remove archive for flow \(flowId): \(error)")
        }
    }
    
    /// Clear all cached archives
    func clearAllArchives() {
        do {
            try FileManager.default.removeItem(at: cacheDirectory)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            LogInfo("Cleared all cached archives")
        } catch {
            LogError("Failed to clear archives: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    /// Generate canonical filesystem path based on flow URL
    private func canonicalURL(for flow: RemoteFlow) -> URL {
        // Use the content hash and flow ID for canonical path
        // This ensures same content = same file
        let hash = flow.manifest.contentHash
        let locale = flow.locale ?? flow.defaultLocale ?? "default"
        let filename = "flow_\(flow.id)_\(sanitizeLocale(locale))_\(hash).webarchive"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func sanitizeLocale(_ locale: String) -> String {
        let pattern = "[^A-Za-z0-9-]"
        return locale.replacingOccurrences(of: pattern, with: "-", options: .regularExpression)
    }
}
