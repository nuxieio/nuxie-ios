import Foundation
import UIKit

/// Manages creation and caching of flow view controllers
@MainActor
final class FlowViewControllerCache {
    
    // MARK: - Properties
    
    // Cache of view controllers by flow ID
    // MainActor-isolated so no need for dispatch queues
    private var cache: [String: FlowViewController] = [:]
    
    // Track which VCs are loaded vs just cached
    private var loadedViewControllers: Set<String> = []
    
    // Flow archiver for creating view controllers
    private let flowArchiver: FlowArchiver
    private let fontStore: FontStore
    
    // MARK: - Initialization
    
    init(flowArchiver: FlowArchiver, fontStore: FontStore) {
        self.flowArchiver = flowArchiver
        self.fontStore = fontStore
        LogDebug("FlowViewControllerCache initialized")
    }
    
    // MARK: - Public Methods
    
    /// 1. Get view controller from cache (returns nil if not cached)
    func getCachedViewController(for flowId: String) -> FlowViewController? {
        return cache[flowId]
    }
    
    /// 2. Create view controller and insert into cache
    func createViewController(for flow: Flow) -> FlowViewController {
        // MainActor ensures we're on main thread
        let viewController = FlowViewController(
            flow: flow,
            archiveService: flowArchiver,
            fontStore: fontStore
        )
        cache[flow.id] = viewController
        return viewController
    }
    
    /// 3. Remove a specific view controller from cache
    func removeViewController(for flowId: String) {
        cache.removeValue(forKey: flowId)
        loadedViewControllers.remove(flowId)
    }
    
    /// 4. Clear all cached view controllers
    func clearCache() {
        cache.removeAll()
        loadedViewControllers.removeAll()
    }
    
    // MARK: - Cache Statistics (for debugging)
    
    /// Get current cache size
    var cacheSize: Int {
        return cache.count
    }
    
    /// Get loaded view controller count
    var loadedCount: Int {
        return loadedViewControllers.count
    }
}
