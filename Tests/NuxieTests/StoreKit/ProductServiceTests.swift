import Foundation
import Quick
import Nimble
import StoreKit
@testable import Nuxie

// MARK: - Tests
final class ProductServiceSpec: AsyncSpec {
    override class func spec() {
        describe("ProductService") {
            var productService: ProductService!
            var mockProvider: MockStoreKitProductProvider!
            
            beforeEach {
                mockProvider = MockStoreKitProductProvider()
                productService = ProductService(productProvider: mockProvider)
            }
            
            afterEach {
                await mockProvider?.reset()
                productService = nil
                mockProvider = nil
            }
            
            describe("initialization") {
                it("should create a ProductService instance") {
                    expect(productService).toNot(beNil())
                    expect(productService).to(beAnInstanceOf(ProductService.self))
                }
                
                it("should use default provider when none specified") {
                    let defaultService = ProductService()
                    expect(defaultService).toNot(beNil())
                }
            }
            
            describe("fetchProducts") {
                context("with valid input") {
                    it("should fetch products successfully") {
                        let identifiers = Set(["com.example.product1", "com.example.product2"])
                        let mockProducts: [any StoreProductProtocol] = [
                            MockStoreProduct(
                                id: "com.example.product1",
                                displayName: "Product 1",
                                description: "Test product 1",
                                price: Decimal(0.99),
                                displayPrice: "$0.99",
                                productType: .consumable
                            ),
                            MockStoreProduct(
                                id: "com.example.product2",
                                displayName: "Product 2",
                                description: "Test product 2",
                                price: Decimal(1.99),
                                displayPrice: "$1.99",
                                productType: .nonConsumable
                            )
                        ]
                        
                        await mockProvider.setProducts(mockProducts)
                        
                        let products = try await productService.fetchProducts(for: identifiers)
                        
                        expect(products).to(haveCount(2))
                        expect(products.map { $0.id }).to(contain("com.example.product1", "com.example.product2"))
                        await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                        await expect { await mockProvider.requestedIdentifiers }.to(equal(identifiers))
                    }
                    
                    it("should handle partial product availability") {
                        let identifiers = Set(["com.example.product1", "com.example.product2", "com.example.product3"])
                        let mockProducts: [any StoreProductProtocol] = [
                            MockStoreProduct(
                                id: "com.example.product1",
                                displayName: "Product 1",
                                description: "Test product 1",
                                price: Decimal(0.99),
                                displayPrice: "$0.99",
                                productType: .consumable
                            )
                        ]
                        
                        await mockProvider.setProducts(mockProducts)
                        
                        let products = try await productService.fetchProducts(for: identifiers)
                        
                        expect(products).to(haveCount(1))
                        expect(products.first?.id).to(equal("com.example.product1"))
                    }
                    
                    it("should handle duplicate identifiers") {
                        let identifiers = Set(["com.example.product1", "com.example.product1"])
                        let mockProducts: [any StoreProductProtocol] = [
                            MockStoreProduct(
                                id: "com.example.product1",
                                displayName: "Product 1",
                                description: "Test product 1",
                                price: Decimal(0.99),
                                displayPrice: "$0.99",
                                productType: .consumable
                            )
                        ]
                        
                        await mockProvider.setProducts(mockProducts)
                        
                        let products = try await productService.fetchProducts(for: identifiers)
                        
                        expect(products).to(haveCount(1))
                        await expect { await mockProvider.requestedIdentifiers?.count }.to(equal(1))
                    }
                }
                
                context("with invalid input") {
                    it("should throw error for empty identifiers") {
                        let identifiers: Set<String> = []
                        
                        await expect {
                            try await productService.fetchProducts(for: identifiers)
                        }.to(throwError(StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")))
                        
                        await expect { await mockProvider.fetchProductsCallCount }.to(equal(0))
                    }
                }
                
                context("with errors") {
                    it("should propagate StoreKit errors") {
                        let identifiers = Set(["com.example.product1"])
                        await mockProvider.setError(StoreKitError.networkUnavailable)
                        
                        await expect {
                            try await productService.fetchProducts(for: identifiers)
                        }.to(throwError(StoreKitError.networkUnavailable))
                        
                        await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                    }
                    
                    it("should wrap generic errors") {
                        let identifiers = Set(["com.example.product1"])
                        let genericError = NSError(domain: "TestError", code: 123, userInfo: nil)
                        await mockProvider.setError(genericError)
                        
                        await expect {
                            try await productService.fetchProducts(for: identifiers)
                        }.to(throwError())
                    }
                }
            }
            
            describe("fetchProducts for RemoteFlows") {
                it("should fetch products for multiple flows") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Flow 1",
                            url: "https://example.com/flow1",
                            products: [
                                RemoteFlowProduct(id: "prod1", extId: "com.example.product1", name: "Product 1"),
                                RemoteFlowProduct(id: "prod2", extId: "com.example.product2", name: "Product 2")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        ),
                        RemoteFlow(
                            id: "flow2",
                            name: "Flow 2",
                            url: "https://example.com/flow2",
                            products: [
                                RemoteFlowProduct(id: "prod3", extId: "com.example.product3", name: "Product 3")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash2",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    let mockProducts: [any StoreProductProtocol] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Product 1",
                            description: "Test product 1",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        ),
                        MockStoreProduct(
                            id: "com.example.product2",
                            displayName: "Product 2",
                            description: "Test product 2",
                            price: Decimal(1.99),
                            displayPrice: "$1.99",
                            productType: .nonConsumable
                        ),
                        MockStoreProduct(
                            id: "com.example.product3",
                            displayName: "Product 3",
                            description: "Test product 3",
                            price: Decimal(2.99),
                            displayPrice: "$2.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
                        )
                    ]
                    
                    await mockProvider.setProducts(mockProducts)
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    expect(flowProducts).to(haveCount(2))
                    expect(flowProducts["flow1"]).to(haveCount(2))
                    expect(flowProducts["flow2"]).to(haveCount(1))
                    
                    expect(flowProducts["flow1"]?.map { $0.id }).to(contain("com.example.product1", "com.example.product2"))
                    expect(flowProducts["flow2"]?.map { $0.id }).to(contain("com.example.product3"))
                    
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                    await expect { await mockProvider.requestedIdentifiers }.to(equal(Set(["com.example.product1", "com.example.product2", "com.example.product3"])))
                }
                
                it("should handle flows with no products") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Flow 1",
                            url: "https://example.com/flow1",
                            products: [],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    expect(flowProducts).to(beEmpty())
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(0))
                }
                
                it("should handle empty flow array") {
                    let flows: [RemoteFlow] = []
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    expect(flowProducts).to(beEmpty())
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(0))
                }
                
                it("should handle flows with duplicate product IDs") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Flow 1",
                            url: "https://example.com/flow1",
                            products: [
                                RemoteFlowProduct(id: "prod1", extId: "com.example.product1", name: "Product 1"),
                                RemoteFlowProduct(id: "prod2", extId: "com.example.product1", name: "Product 1 Duplicate")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        ),
                        RemoteFlow(
                            id: "flow2",
                            name: "Flow 2",
                            url: "https://example.com/flow2",
                            products: [
                                RemoteFlowProduct(id: "prod3", extId: "com.example.product1", name: "Product 1 Again")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash2",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    let mockProducts: [any StoreProductProtocol] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Product 1",
                            description: "Test product 1",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        )
                    ]
                    
                    await mockProvider.setProducts(mockProducts)
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    // Should only fetch the unique product once
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                    await expect { await mockProvider.requestedIdentifiers }.to(equal(Set(["com.example.product1"])))
                    
                    // Flow1 should have the product appear twice (once for each RemoteFlowProduct)
                    // since compactMap will include it for each matching extId
                    expect(flowProducts["flow1"]).to(haveCount(2))
                    expect(flowProducts["flow2"]).to(haveCount(1))
                    expect(flowProducts["flow1"]?.allSatisfy { $0.id == "com.example.product1" }).to(beTrue())
                    expect(flowProducts["flow2"]?.first?.id).to(equal("com.example.product1"))
                }
                
                it("should handle missing products from StoreKit") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Flow 1",
                            url: "https://example.com/flow1",
                            products: [
                                RemoteFlowProduct(id: "prod1", extId: "com.example.product1", name: "Product 1"),
                                RemoteFlowProduct(id: "prod2", extId: "com.example.missing", name: "Missing Product")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    let mockProducts: [any StoreProductProtocol] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Product 1",
                            description: "Test product 1",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        )
                    ]
                    
                    await mockProvider.setProducts(mockProducts)
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    // Should only return the product that was found
                    expect(flowProducts["flow1"]).to(haveCount(1))
                    expect(flowProducts["flow1"]?.first?.id).to(equal("com.example.product1"))
                    
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                    await expect { await mockProvider.requestedIdentifiers }.to(equal(Set(["com.example.product1", "com.example.missing"])))
                }
                
                it("should handle flows with subscription products") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Subscription Flow",
                            url: "https://example.com/flow1",
                            products: [
                                RemoteFlowProduct(id: "prod1", extId: "com.example.weekly", name: "Weekly Sub"),
                                RemoteFlowProduct(id: "prod2", extId: "com.example.monthly", name: "Monthly Sub"),
                                RemoteFlowProduct(id: "prod3", extId: "com.example.yearly", name: "Yearly Sub")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    let mockProducts: [any StoreProductProtocol] = [
                        MockStoreProduct(
                            id: "com.example.weekly",
                            displayName: "Weekly Subscription",
                            description: "Billed weekly",
                            price: Decimal(4.99),
                            displayPrice: "$4.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .week)
                        ),
                        MockStoreProduct(
                            id: "com.example.monthly",
                            displayName: "Monthly Subscription",
                            description: "Billed monthly",
                            price: Decimal(9.99),
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
                        ),
                        MockStoreProduct(
                            id: "com.example.yearly",
                            displayName: "Yearly Subscription",
                            description: "Billed yearly",
                            price: Decimal(99.99),
                            displayPrice: "$99.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year)
                        )
                    ]
                    
                    await mockProvider.setProducts(mockProducts)
                    
                    let flowProducts = try await productService.fetchProducts(for: flows)
                    
                    expect(flowProducts["flow1"]).to(haveCount(3))
                    
                    let products = flowProducts["flow1"] ?? []
                    let weekly = products.first { $0.id == "com.example.weekly" }
                    let monthly = products.first { $0.id == "com.example.monthly" }
                    let yearly = products.first { $0.id == "com.example.yearly" }
                    
                    expect(weekly?.subscriptionPeriod?.unit).to(equal(.week))
                    expect(monthly?.subscriptionPeriod?.unit).to(equal(.month))
                    expect(yearly?.subscriptionPeriod?.unit).to(equal(.year))
                }
                
                it("should propagate errors from provider") {
                    let flows = [
                        RemoteFlow(
                            id: "flow1",
                            name: "Flow 1",
                            url: "https://example.com/flow1",
                            products: [
                                RemoteFlowProduct(id: "prod1", extId: "com.example.product1", name: "Product 1")
                            ],
                            manifest: BuildManifest(
                                totalFiles: 1,
                                totalSize: 100,
                                contentHash: "hash1",
                                files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                            )
                        )
                    ]
                    
                    await mockProvider.setError(StoreKitError.networkUnavailable)
                    
                    await expect {
                        try await productService.fetchProducts(for: flows)
                    }.to(throwError(StoreKitError.networkUnavailable))
                    
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                }
            }
            
            describe("product properties") {
                it("should preserve all product properties") {
                    let identifiers = Set(["com.example.product1"])
                    
                    let mockProducts: [any StoreProductProtocol] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Test Product",
                            description: "A test product description",
                            price: Decimal(9.99),
                            displayPrice: "$9.99",
                            isFamilyShareable: true,
                            productType: .nonConsumable
                        )
                    ]
                    
                    await mockProvider.setProducts(mockProducts)
                    
                    let products = try await productService.fetchProducts(for: identifiers)
                    
                    expect(products).to(haveCount(1))
                    guard let product = products.first else {
                        fail("Expected to find a product")
                        return
                    }
                    
                    expect(product.id).to(equal("com.example.product1"))
                    expect(product.displayName).to(equal("Test Product"))
                    expect(product.description).to(equal("A test product description"))
                    expect(product.price).to(equal(Decimal(9.99)))
                    expect(product.displayPrice).to(equal("$9.99"))
                    expect(product.isFamilyShareable).to(beTrue())
                    expect(product.productType).to(equal(.nonConsumable))
                }
            }
        }
    }
}