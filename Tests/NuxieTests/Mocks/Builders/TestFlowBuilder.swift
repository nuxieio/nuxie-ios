import Foundation
@testable import Nuxie

/// Builder for creating test flows with fluent API
class TestFlowBuilder {
    private var id: String
    private var name: String
    private var url: String
    private var products: [RemoteFlowProduct]
    private var manifest: BuildManifest
    
    init(id: String = "test-flow") {
        self.id = id
        self.name = "Test Flow"
        self.url = "https://example.com/flow"
        self.products = []
        self.manifest = BuildManifest(
            totalFiles: 0,
            totalSize: 0,
            contentHash: "test-hash",
            files: []
        )
    }
    
    func withId(_ id: String) -> TestFlowBuilder {
        self.id = id
        return self
    }
    
    func withName(_ name: String) -> TestFlowBuilder {
        self.name = name
        return self
    }
    
    func withUrl(_ url: String) -> TestFlowBuilder {
        self.url = url
        return self
    }
    
    func withProducts(_ products: [RemoteFlowProduct]) -> TestFlowBuilder {
        self.products = products
        return self
    }
    
    func addProduct(id: String, extId: String, name: String) -> TestFlowBuilder {
        let product = RemoteFlowProduct(id: id, extId: extId, name: name)
        self.products.append(product)
        return self
    }
    
    func withManifest(_ manifest: BuildManifest) -> TestFlowBuilder {
        self.manifest = manifest
        return self
    }
    
    func build() -> RemoteFlow {
        return RemoteFlow(
            id: id,
            name: name,
            url: url,
            products: products,
            manifest: manifest
        )
    }
}