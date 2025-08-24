import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class TransactionServiceTests: AsyncSpec {
    override class func spec() {
        describe("TransactionService") {
            var transactionService: TransactionService!
            var mocks: MockFactory!
            var mockPurchaseDelegate: MockPurchaseDelegate!
            var mockProduct: MockStoreProduct!
            
            beforeEach {
                // Register mocks using MockFactory
                mocks = MockFactory.shared
                mocks.registerAll()
                
                // Create mock purchase delegate
                mockPurchaseDelegate = MockPurchaseDelegate()
                
                // Create a test configuration with the purchase delegate
                let config = NuxieConfiguration(apiKey: "test-api-key")
                config.purchaseDelegate = mockPurchaseDelegate
                
                // Setup SDK with configuration (required for TransactionService to access controller)
                try? NuxieSDK.shared.setup(with: config)
                
                // Create transaction service which will use @Injected
                transactionService = TransactionService()
                
                // Create mock product
                mockProduct = MockStoreProduct(
                    id: "com.test.product",
                    displayName: "Test Product",
                    description: "Test Description",
                    price: 9.99,
                    displayPrice: "$9.99"
                )
            }
            
            afterEach {
                // Clean up
                mockPurchaseDelegate.reset()
                await NuxieSDK.shared.shutdown()
            }
            
            describe("purchase") {
                context("with purchase delegate configured") {
                    it("should successfully complete a purchase") {
                        mockPurchaseDelegate.configureForSuccess()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.id).to(equal(mockProduct.id))
                    }
                    
                    it("should throw purchaseCancelled when user cancels") {
                        mockPurchaseDelegate.configureForCancellation()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchaseCancelled))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                    
                    it("should throw purchaseFailed when purchase fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.configureForFailure(error: error)
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                    
                    it("should throw purchasePending when purchase is pending") {
                        mockPurchaseDelegate.configureForPending()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                }
                
                context("without purchase delegate configured") {
                    it("should throw notConfigured error") {
                        // Create new SDK instance without purchase delegate
                        await NuxieSDK.shared.shutdown()
                        let config = NuxieConfiguration(apiKey: "test-api-key")
                        // Don't set purchaseDelegate
                        try? NuxieSDK.shared.setup(with: config)
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.notConfigured))
                    }
                }
            }
            
            describe("restore") {
                context("with purchase delegate configured") {
                    it("should successfully restore purchases") {
                        mockPurchaseDelegate.restoreResult = .success(restoredCount: 2)
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                    
                    it("should handle no purchases to restore") {
                        mockPurchaseDelegate.configureForNoPurchases()
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                    
                    it("should throw restoreFailed when restore fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.restoreResult = .failed(error)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                }
                
                context("without purchase delegate configured") {
                    it("should throw notConfigured error") {
                        // Create new SDK instance without purchase delegate
                        await NuxieSDK.shared.shutdown()
                        let config = NuxieConfiguration(apiKey: "test-api-key")
                        // Don't set purchaseDelegate
                        try? NuxieSDK.shared.setup(with: config)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError(StoreKitError.notConfigured))
                    }
                }
            }
        }
    }
}
