import Foundation
import Quick
import Nimble
import FactoryKit
import UIKit
@testable import Nuxie

final class FlowPresentationServiceTests: AsyncSpec {
    override class func spec() {
        var service: FlowPresentationService!
        var mockFlowService: MockFlowService!
        var mockEventService: MockEventService!
        var mockWindowProvider: MockWindowProvider!
        
        beforeEach { @MainActor in
            // Reset container
            Container.shared.reset()
            
            // Register test configuration
            let testConfig = NuxieConfiguration(apiKey: "test-api-key")
            Container.shared.sdkConfiguration.register { testConfig }
            
            // Register all required mock dependencies
            Container.shared.identityService.register { MockIdentityService() }
            Container.shared.segmentService.register { MockSegmentService() }
            Container.shared.profileService.register { MockProfileService() }
            Container.shared.nuxieApi.register { MockNuxieApi() }
            Container.shared.dateProvider.register { MockDateProvider() }
            Container.shared.sleepProvider.register { MockSleepProvider() }
            Container.shared.productService.register { MockProductService() }
            
            // Setup mock flow service
            mockFlowService = MockFlowService()
            Container.shared.flowService.register { mockFlowService }
            
            // Setup mock event service
            mockEventService = MockEventService()
            Container.shared.eventService.register { mockEventService }
            
            // Setup mock window provider
            mockWindowProvider = MockWindowProvider()
            
            // Create service with mock window provider
            service = FlowPresentationService(windowProvider: mockWindowProvider)
        }
        
        afterEach { @MainActor in
            // Clean up
            mockWindowProvider.reset()
            Container.shared.reset()
        }
        
        describe("presentFlow") {
            context("when window scene is available") {
                it("should create a presentation window") {
                    // Setup
                    let flowId = "test-flow-1"
                    let mockVC = MockFlowViewController(mockFlowId: flowId)
                    mockFlowService.mockViewControllers[flowId] = mockVC
                    
                    // Act
                    await expect {
                        try await service.presentFlow(flowId, from: nil)
                    }.toNot(throwError())
                    
                    // Assert
                    await expect { await service.isFlowPresented }.to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }
                
                it("should set up dismissal handler on flow view controller") {
                    // Setup
                    let flowId = "test-flow-handler"
                    let mockVC = MockFlowViewController(mockFlowId: flowId)
                    mockFlowService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentFlow(flowId, from: nil)
                    
                    // Verify onClose handler is set
                    expect(mockVC.onClose).toNot(beNil())
                }
                
                it("should handle flow dismissal and cleanup") {
                    // Setup
                    let flowId = "test-flow-dismissal"
                    let mockVC = MockFlowViewController(mockFlowId: flowId)
                    mockFlowService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentFlow(flowId, from: nil)
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Simulate dismissal via onClose callback
                    await mockVC.onClose?(.userDismissed)
                    
                    // Wait for cleanup to complete
                    await expect { await service.isFlowPresented }
                        .toEventually(beFalse(), timeout: .seconds(2))
                    
                    // Verify window was cleaned up
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.destroyCalled).to(beTrue())
                    expect(window?.presentedViewController).to(beNil())
                }
                
                it("should dismiss existing flow before presenting new one") {
                    // Present first flow
                    let flowId1 = "flow-1"
                    let mockVC1 = MockFlowViewController(mockFlowId: flowId1)
                    mockFlowService.mockViewControllers[flowId1] = mockVC1
                    
                    try! await service.presentFlow(flowId1, from: nil)
                    await expect { await service.isFlowPresented }.to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Present second flow
                    let flowId2 = "flow-2"
                    let mockVC2 = MockFlowViewController(mockFlowId: flowId2)
                    mockFlowService.mockViewControllers[flowId2] = mockVC2
                    
                    try! await service.presentFlow(flowId2, from: nil)
                    
                    // Should still be presenting (the new one)
                    await expect { await service.isFlowPresented }.to(beTrue())
                    
                    // Should have created a new window
                    expect(mockWindowProvider.createdWindows.count).to(equal(2))
                }
                
                it("should present view controller in window") {
                    // Setup
                    let flowId = "test-key-window"
                    let mockVC = MockFlowViewController(mockFlowId: flowId)
                    mockFlowService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentFlow(flowId, from: nil)
                    
                    // Verify window presentation
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    await expect { await window?.isPresenting }.to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }
            }
            
            context("when window scene is not available") {
                beforeEach {
                    mockWindowProvider.simulateNoScene()
                }
                
                it("should throw noActiveScene error") {
                    await expect {
                        try await service.presentFlow("test-flow", from: nil)
                    }.to(throwError(FlowPresentationError.noActiveScene))
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }
            }
            
            context("when flow service fails") {
                it("should propagate flow service errors") {
                    // Setup flow service to fail
                    mockFlowService.shouldFailFlowDisplay = true
                    mockFlowService.failureError = FlowError.flowNotFound("missing-flow")
                    
                    // Act & Assert
                    await expect {
                        try await service.presentFlow("missing-flow", from: nil)
                    }.to(throwError())
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                    await expect { await service.isFlowPresented }.to(beFalse())
                }
            }
        }
        
        describe("dismissCurrentFlow") {
            it("should dismiss presented flow") {
                // Present a flow first
                let flowId = "test-dismiss"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentFlow(flowId, from: nil)
                await expect { await service.isFlowPresented }.to(beTrue())
                
                // Dismiss it
                await service.dismissCurrentFlow()
                
                // Verify dismissal
                await expect { await service.isFlowPresented }.to(beFalse())
                let window = mockWindowProvider.createdWindows.first
                expect(window?.dismissCalled).to(beTrue())
            }
            
            it("should handle dismissal when no flow is presented") {
                // No flow presented
                await expect { await service.isFlowPresented }.to(beFalse())
                
                // Should not crash
                await service.dismissCurrentFlow()
                
                // Still no flow
                await expect { await service.isFlowPresented }.to(beFalse())
            }
        }
        
        describe("isFlowPresented") {
            it("should reflect presentation state accurately") {
                // Initially no flow
                await expect { await service.isFlowPresented }.to(beFalse())
                
                // Present flow
                let flowId = "state-test"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentFlow(flowId, from: nil)
                await expect { await service.isFlowPresented }.to(beTrue())
                
                // Dismiss flow
                await service.dismissCurrentFlow()
                await expect { await service.isFlowPresented }.to(beFalse())
            }
        }
        
        describe("journey integration") {
            it("should accept journey context") { @MainActor in
                // Create mock campaign and journey using TestBuilders
                let campaign = TestCampaignBuilder(id: "campaign-1")
                    .withName("Test Campaign")
                    .withFrequencyPolicy("once_per_user")
                    .withEventTrigger(eventName: "test_event")
                    .build()
                
                let journey = Journey(
                    campaign: campaign,
                    distinctId: "user-1"
                )
                
                // Present with journey
                let flowId = "journey-flow"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                await expect {
                    try await service.presentFlow(flowId, from: journey)
                }.toNot(throwError())
                
                // Verify presentation
                await expect { await service.isFlowPresented }.to(beTrue())
                
                // Verify journey context is stored
                expect(service.currentJourney?.id).toNot(beNil())
            }
            
            it("should handle nil journey context") { @MainActor in
                let flowId = "no-journey-flow"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                await expect {
                    try await service.presentFlow(flowId, from: nil)
                }.toNot(throwError())
                
                await expect { await service.isFlowPresented }.to(beTrue())
                expect(service.currentJourney).to(beNil())
            }
        }
        
        describe("window management") {
            it("should create window and present view controller") { @MainActor in
                let flowId = "window-props"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentFlow(flowId, from: nil)
                
                let window = mockWindowProvider.createdWindows.first
                expect(window).toNot(beNil())
                expect(window?.presentCalled).to(beTrue())
                expect(window?.presentedViewController).to(equal(mockVC))
                await expect { await window?.isPresenting }.to(beTrue())
            }
            
            it("should properly clean up window on dismissal") { @MainActor in
                let flowId = "cleanup-test"
                let mockVC = MockFlowViewController(mockFlowId: flowId)
                mockFlowService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentFlow(flowId, from: nil)
                let window = mockWindowProvider.createdWindows.first
                
                // Simulate dismissal
                await mockVC.onClose?(.purchaseCompleted(productId: "test_product", transactionId: nil))
                
                // Wait for cleanup
                await expect { await service.isFlowPresented }
                    .toEventually(beFalse(), timeout: .seconds(2))
                
                // Verify cleanup
                expect(window?.destroyCalled).to(beTrue())
                expect(window?.presentedViewController).to(beNil())
            }
        }
    }
}
