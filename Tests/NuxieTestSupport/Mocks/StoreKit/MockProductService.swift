import Foundation
@testable import Nuxie

/// Mock implementation of ProductService for testing
public class MockProductService: ProductService {
    public var fetchProductsCalled = false
    public var requestedProductIds: Set<String> = []
    public var mockProducts: [any StoreProductProtocol] = []
    public var shouldThrowError = false
    
    public override func fetchProducts(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        fetchProductsCalled = true
        requestedProductIds = identifiers
        if shouldThrowError {
            throw StoreKitError.networkUnavailable
        }
        return mockProducts
    }
    
    public func reset() {
        fetchProductsCalled = false
        requestedProductIds = []
        mockProducts = []
        shouldThrowError = false
    }
}
