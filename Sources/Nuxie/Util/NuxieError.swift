import Foundation

public enum NuxieError: LocalizedError {
    case notConfigured
    case invalidConfiguration(String)
    case alreadyConfigured
    case networkError(Error)
    case paywallNotFound(String)
    case storageError(Error)
    case invalidEvent(String)
    case eventDropped(String)
    case eventRoutingFailed
    
    // Flow-specific errors
    case flowDownloadFailed(String, Error)
    case flowCacheFailed(String, Error)
    case flowNotCached(String)
    case webArchiveCreationFailed(Error)
    case flowManagerNotInitialized
    case flowError(String)
    case configurationError(String)

    // Feature-specific errors
    case featureNotFound(String)
    case featureCheckFailed(String, Error)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Nuxie SDK is not configured"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .alreadyConfigured:
            return "Nuxie SDK is already configured"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .paywallNotFound(let id):
            return "Paywall not found: \(id)"
        case .storageError(let error):
            return "Storage error: \(error.localizedDescription)"
        case .invalidEvent(let reason):
            return "Invalid event: \(reason)"
        case .eventDropped(let reason):
            return "Event dropped: \(reason)"
        case .eventRoutingFailed:
            return "Event routing failed"
        case .flowDownloadFailed(let flowId, let error):
            return "Failed to download flow \(flowId): \(error.localizedDescription)"
        case .flowCacheFailed(let flowId, let error):
            return "Failed to cache flow \(flowId): \(error.localizedDescription)"
        case .flowNotCached(let flowId):
            return "Flow \(flowId) is not cached"
        case .webArchiveCreationFailed(let error):
            return "Failed to create WebArchive: \(error.localizedDescription)"
        case .flowManagerNotInitialized:
            return "Flow manager is not initialized"
        case .flowError(let message):
            return "Flow error: \(message)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .featureNotFound(let featureId):
            return "Feature not found: \(featureId)"
        case .featureCheckFailed(let featureId, let error):
            return "Feature check failed for \(featureId): \(error.localizedDescription)"
        }
    }
}