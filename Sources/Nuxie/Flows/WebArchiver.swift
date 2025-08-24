import Foundation

/// Handles parallel downloading with manifest-level deduplication only
actor WebArchiver {
    
    // MARK: - Properties
    
    // Deduplication at manifest level only - each manifest is isolated
    private var activeDownloads: [String: Task<Data, Error>] = [:]
    
    // URLSession for network operations (injectable for testing)
    private let urlSession: URLSession
    
    // MARK: - Initialization
    
    init(urlSession: URLSession = URLSession.shared) {
        self.urlSession = urlSession
        LogDebug("WebArchiver initialized")
    }
    
    // MARK: - Public Methods
    
    /// Download manifest files and build WebArchive
    func downloadAndBuildArchive(
        manifest: BuildManifest,
        baseURL: URL
    ) async throws -> Data {
        let manifestKey = manifest.contentHash
        
        LogDebug("Starting archive build for manifest: \(manifestKey)")
        
        // Check for active download of same manifest
        if let existingTask = activeDownloads[manifestKey] {
            LogDebug("Awaiting existing download for manifest: \(manifestKey)")
            return try await existingTask.value
        }
        
        // Start new download
        let task = Task<Data, Error> {
            defer { activeDownloads[manifestKey] = nil }
            return try await performDownload(manifest: manifest, baseURL: baseURL, key: manifestKey)
        }
        
        activeDownloads[manifestKey] = task
        return try await task.value
    }
    
    // MARK: - Private Methods
    
    private func performDownload(manifest: BuildManifest, baseURL: URL, key: String) async throws -> Data {
        LogDebug("Downloading \(manifest.files.count) files for manifest: \(key)")
        
        // Download all files in parallel using TaskGroup
        let downloadedFiles = try await withThrowingTaskGroup(of: (BuildFile, Data).self) { group in
            var files: [BuildFile: Data] = [:]
            
            // Add download task for each file
            for file in manifest.files {
                group.addTask { [urlSession] in
                    let fileURL = baseURL.appendingPathComponent(file.path)
                    
                    let (data, _) = try await urlSession.data(from: fileURL)
                    LogDebug("Downloaded \(file.path) (\(data.count) bytes)")
                    return (file, data)
                }
            }
            
            // Collect results
            for try await (file, data) in group {
                files[file] = data
            }
            
            return files
        }
        
        if downloadedFiles.isEmpty && !manifest.files.isEmpty {
            throw FlowError.downloadFailed
        }
        
        // Build WebArchive from downloaded files
        return try buildWebArchive(from: downloadedFiles, manifest: manifest, baseURL: baseURL)
    }
    
    private func buildWebArchive(from files: [BuildFile: Data], manifest: BuildManifest, baseURL: URL) throws -> Data {
        LogDebug("Building WebArchive with \(files.count) files")
        
        // Find the main HTML file (prefer index.html, then any HTML file, then first file)
        let htmlFile = manifest.files.first { $0.path.contains("index.html") } 
            ?? manifest.files.first { $0.contentType.contains("html") } 
            ?? manifest.files.first
            
        guard let mainFile = htmlFile,
              let mainData = files[mainFile] else {
            LogError("No main file found in manifest")
            throw FlowError.invalidManifest
        }
        
        // Build WebArchive plist structure
        var plist: [String: Any] = [:]
        
        // Main resource
        let mainURL = baseURL.appendingPathComponent(mainFile.path)
        plist["WebMainResource"] = [
            "WebResourceURL": mainURL.absoluteString,
            "WebResourceMIMEType": mainFile.contentType,
            "WebResourceTextEncodingName": "UTF-8",
            "WebResourceData": mainData
        ]
        
        // Subresources for other files
        var subresources: [[String: Any]] = []
        for (file, data) in files where file != mainFile {
            let resourceURL = baseURL.appendingPathComponent(file.path)
            var resource: [String: Any] = [
                "WebResourceURL": resourceURL.absoluteString,
                "WebResourceMIMEType": file.contentType,
                "WebResourceData": data
            ]
            // Add text encoding for text files
            if file.contentType.contains("text") || file.contentType.contains("javascript") || file.contentType.contains("css") {
                resource["WebResourceTextEncodingName"] = "UTF-8"
            }
            subresources.append(resource)
        }
        
        if !subresources.isEmpty {
            plist["WebSubresources"] = subresources
        }
        
        // Serialize to binary plist (WebArchive format)
        let webArchiveData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        LogDebug("Built WebArchive successfully (\(webArchiveData.count) bytes)")
        return webArchiveData
    }
}

