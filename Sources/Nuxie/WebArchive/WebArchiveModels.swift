import Foundation

/// Data models for WebKit WebArchive format
/// WebArchive is a plist-based format that contains a main resource and subresources

// MARK: - WebArchive Structure

/// Root WebArchive structure
struct WebArchive: Codable {
    let webMainResource: WebResource
    let webSubresources: [WebResource]
    
    private enum CodingKeys: String, CodingKey {
        case webMainResource = "WebMainResource"
        case webSubresources = "WebSubresources"
    }
}

/// Individual resource within a WebArchive
struct WebResource: Codable {
    let url: String
    let data: Data
    let mimeType: String
    let textEncodingName: String?
    
    private enum CodingKeys: String, CodingKey {
        case url = "WebResourceURL"
        case data = "WebResourceData"
        case mimeType = "WebResourceMIMEType"
        case textEncodingName = "WebResourceTextEncodingName"
    }
    
    init(url: String, data: Data, mimeType: String, textEncodingName: String? = nil) {
        self.url = url
        self.data = data
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
    }
}

// MARK: - Download Models

/// Represents a downloaded file with metadata
struct DownloadedFile {
    let buildFile: BuildFile
    let data: Data
    let sourceURL: URL
    let localURL: URL?
    
    /// Computed absolute URL for the resource
    var absoluteURL: String {
        return sourceURL.absoluteString
    }
    
    /// MIME type from BuildFile or inferred from file extension
    var mimeType: String {
        if !buildFile.contentType.isEmpty {
            return buildFile.contentType
        }
        
        // Fallback to file extension-based MIME type detection
        let pathExtension = URL(string: buildFile.path)?.pathExtension.lowercased() ?? ""
        return MIMETypeHelper.mimeType(for: pathExtension)
    }
    
    /// Text encoding for text-based resources
    var textEncodingName: String? {
        if mimeType.hasPrefix("text/") || mimeType.contains("javascript") || mimeType.contains("json") {
            return "UTF-8"
        }
        return nil
    }
}

/// Cached flow with metadata
struct CachedFlow: Codable {
    let flowId: String
    let flowName: String
    let webArchiveData: Data
    let cachedAt: Date
    let flowVersion: String?
    let totalSize: Int64
    let frameCount: Int
    
    init(flow: Flow, webArchiveData: Data) {
        self.flowId = flow.id
        self.flowName = flow.name
        self.webArchiveData = webArchiveData
        self.cachedAt = Date()
        self.flowVersion = nil // Could be added to Flow model later
        self.totalSize = Int64(webArchiveData.count)
        self.frameCount = 1 // Flow now represents a single frame
    }
}

// MARK: - Helper Classes

/// Helper for MIME type detection
struct MIMETypeHelper {
    private static let mimeTypes: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "application/javascript",
        "json": "application/json",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "eot": "application/vnd.ms-fontobject",
        "pdf": "application/pdf",
        "zip": "application/zip"
    ]
    
    static func mimeType(for fileExtension: String) -> String {
        return mimeTypes[fileExtension.lowercased()] ?? "application/octet-stream"
    }
    
    static func isTextBased(_ mimeType: String) -> Bool {
        return mimeType.hasPrefix("text/") || 
               mimeType.contains("javascript") || 
               mimeType.contains("json") ||
               mimeType.contains("xml")
    }
}

// MARK: - Flow Cache Metadata

/// Metadata for flow cache management
struct FlowCacheMetadata: Codable {
    let flowId: String
    let cachedAt: Date
    let lastAccessed: Date
    let size: Int64
    let version: String?
    let frameUrls: [String]
    let downloadDuration: TimeInterval
    let fileCount: Int
    
    var age: TimeInterval {
        return Date().timeIntervalSince(cachedAt)
    }
    
    var isExpired: Bool {
        return age > (7 * 24 * 3600) // 7 days default expiration
    }
}