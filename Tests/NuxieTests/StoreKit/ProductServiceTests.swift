import Foundation
import Quick
import Nimble
import StoreKit
@testable import Nuxie

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

            describe("fetchProducts") {
                it("fetches products successfully") {
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

                it("handles partial product availability") {
                    let identifiers = Set(["com.example.product1", "com.example.product2"])
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

                it("throws on empty identifiers") {
                    let identifiers: Set<String> = []

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError(StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")))

                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(0))
                }

                it("propagates StoreKit errors") {
                    let identifiers = Set(["com.example.product1"])
                    await mockProvider.setError(StoreKitError.networkUnavailable)

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError(StoreKitError.networkUnavailable))

                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                }

                it("wraps generic errors") {
                    let identifiers = Set(["com.example.product1"])
                    let genericError = NSError(domain: "TestError", code: 123, userInfo: nil)
                    await mockProvider.setError(genericError)

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError())
                }
            }

            describe("product properties") {
                it("preserves product properties") {
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
