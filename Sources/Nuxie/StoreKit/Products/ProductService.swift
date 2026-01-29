import Foundation
import StoreKit

public class ProductService {
    private let productProvider: StoreKitProductProvider
    
    public init(productProvider: StoreKitProductProvider = DefaultStoreKitProductProvider()) {
        self.productProvider = productProvider
    }
    
    public func fetchProducts(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        guard !identifiers.isEmpty else {
            throw StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")
        }
        
        do {
            let products = try await productProvider.products(for: identifiers)
            
            if products.isEmpty {
                LogError("No products found for identifiers: \(identifiers)")
            }
            
            let fetchedIds = Set(products.map { $0.id })
            let missingIds = identifiers.subtracting(fetchedIds)
            
            if !missingIds.isEmpty {
                LogWarning("Some products not found: \(missingIds)")
            }
            
            return products
        } catch let error as StoreKitError {
            throw error
        } catch {
            throw StoreKitError.from(storeKit2Error: error)
        }
    }
    
    public func fetchProducts(for remoteFlows: [RemoteFlow]) async throws -> [String: [any StoreProductProtocol]] {
        // Collect all unique product IDs across all flows
        let allProductIds = Set(remoteFlows.flatMap { $0.products.map { $0.extId } })
        
        guard !allProductIds.isEmpty else {
            LogDebug("No products to fetch across \(remoteFlows.count) flows")
            return [:]
        }
        
        LogDebug("Fetching \(allProductIds.count) unique products for \(remoteFlows.count) flows")
        
        // Fetch all products in one batch
        let allProducts = try await fetchProducts(for: allProductIds)
        
        // Create a lookup dictionary for efficient mapping
        let productLookup = Dictionary(uniqueKeysWithValues: allProducts.map { ($0.id, $0) })
        
        // Map products back to their respective flows
        var flowProducts: [String: [any StoreProductProtocol]] = [:]
        for flow in remoteFlows {
            let flowProductIds = flow.products.map { $0.extId }
            flowProducts[flow.id] = flowProductIds.compactMap { productLookup[$0] }
        }
        
        return flowProducts
    }
}