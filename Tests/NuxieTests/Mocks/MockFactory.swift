import Foundation
import FactoryKit
@testable import Nuxie

/// Factory for creating and managing shared mock instances
public class MockFactory {
    public static let shared = MockFactory()

    private static let usageLock = NSLock()
    private static var _wasUsed = false
    
    private init() {}

    static func resetUsageFlag() {
        usageLock.lock()
        _wasUsed = false
        usageLock.unlock()
    }

    static func markUsed() {
        usageLock.lock()
        _wasUsed = true
        usageLock.unlock()
    }

    static var wasUsed: Bool {
        usageLock.lock()
        defer { usageLock.unlock() }
        return _wasUsed
    }
    
    // Lazy instances - these will use the individual mock files
    private lazy var _identityService = MockIdentityService()
    private lazy var _segmentService = MockSegmentService()
    private lazy var _journeyStore = MockJourneyStore()
    private lazy var _journeyExecutor = MockJourneyExecutor()
    private lazy var _profileService = MockProfileService()
    private lazy var _eventService = MockEventService()
    private lazy var _eventStore = MockEventStore()
    private lazy var _nuxieApi = MockNuxieApi()
    private lazy var _flowService = MockFlowService()
    private lazy var _flowPresentationService = MockFlowPresentationService()
    private lazy var _dateProvider = MockDateProvider()
    private lazy var _sleepProvider = MockSleepProvider()
    private lazy var _productService = MockProductService()
    
    // Public accessors
    public var identityService: MockIdentityService { Self.markUsed(); return _identityService }
    public var segmentService: MockSegmentService { Self.markUsed(); return _segmentService }
    public var journeyStore: MockJourneyStore { Self.markUsed(); return _journeyStore }
    public var journeyExecutor: MockJourneyExecutor { Self.markUsed(); return _journeyExecutor }
    public var profileService: MockProfileService { Self.markUsed(); return _profileService }
    public var eventService: MockEventService { Self.markUsed(); return _eventService }
    public var eventStore: MockEventStore { Self.markUsed(); return _eventStore }
    public var nuxieApi: MockNuxieApi { Self.markUsed(); return _nuxieApi }
    public var flowService: MockFlowService { Self.markUsed(); return _flowService }
    public var flowPresentationService: MockFlowPresentationService { Self.markUsed(); return _flowPresentationService }
    public var dateProvider: MockDateProvider { Self.markUsed(); return _dateProvider }
    public var sleepProvider: MockSleepProvider { Self.markUsed(); return _sleepProvider }
    public var productService: MockProductService { Self.markUsed(); return _productService }
    
    /// Reset all mock services to their initial state
    public func resetAll() async {
        Self.markUsed()
        identityService.reset()
        await segmentService.reset()
        journeyStore.reset()
        journeyExecutor.reset()
        profileService.reset()
        eventService.reset()
        await eventStore.reset()
        await nuxieApi.reset()
        flowService.reset()
        flowPresentationService.reset()
        dateProvider.reset()
        sleepProvider.reset()
        productService.reset()
    }
    
    /// Register all services with mocks using Factory
    public func registerAll() {
        Self.markUsed()
        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { self.identityService }
        Container.shared.segmentService.register { self.segmentService }
        // journeyStore and journeyExecutor are no longer registered in the container
        // They are injected directly into JourneyService via constructor
        Container.shared.profileService.register { self.profileService }
        Container.shared.eventService.register { self.eventService }
        Container.shared.nuxieApi.register { self.nuxieApi }
        Container.shared.flowService.register { self.flowService }
        Container.shared.flowPresentationService.register { self.flowPresentationService }
        Container.shared.dateProvider.register { self.dateProvider }
        Container.shared.sleepProvider.register { self.sleepProvider }
        Container.shared.productService.register { self.productService }
    }
    
    /// Register services for integration tests - mocks external dependencies but uses real business logic
    public func registerForIntegrationTests() {
        Self.markUsed()
        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { self.identityService }
        Container.shared.segmentService.register { self.segmentService }
        // journeyStore and journeyExecutor are no longer registered in the container
        // They are injected directly into JourneyService via constructor
        Container.shared.profileService.register { self.profileService }
        Container.shared.eventService.register { self.eventService }
        Container.shared.nuxieApi.register { self.nuxieApi }
        Container.shared.flowService.register { self.flowService }
        // DON'T register flowPresentationService - let real implementation run for integration tests
        Container.shared.dateProvider.register { self.dateProvider }
        Container.shared.sleepProvider.register { self.sleepProvider }
        Container.shared.productService.register { self.productService }
    }
    
    /// Reset all Factory registrations
    public func resetAllFactories() {
        Self.markUsed()
        Container.shared.reset()
    }
}
