import Foundation
import StoreKit

public protocol StoreKitProductProvider {
    func products(for identifiers: Set<String>) async throws -> [any StoreProductProtocol]
}

public class DefaultStoreKitProductProvider: StoreKitProductProvider {
    public init() {}
    
    public func products(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        let products = try await Product.products(for: identifiers)
        // Products already conform to StoreProductProtocol via our extension
        return products
    }
}