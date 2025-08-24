import Foundation
import FactoryKit
@testable import Nuxie

/// Factory for creating and managing shared mock instances
public class MockFactory {
    public static let shared = MockFactory()
    
    private init() {}
    
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
    public var identityService: MockIdentityService { _identityService }
    public var segmentService: MockSegmentService { _segmentService }
    public var journeyStore: MockJourneyStore { _journeyStore }
    public var journeyExecutor: MockJourneyExecutor { _journeyExecutor }
    public var profileService: MockProfileService { _profileService }
    public var eventService: MockEventService { _eventService }
    public var eventStore: MockEventStore { _eventStore }
    public var nuxieApi: MockNuxieApi { _nuxieApi }
    public var flowService: MockFlowService { _flowService }
    public var flowPresentationService: MockFlowPresentationService { _flowPresentationService }
    public var dateProvider: MockDateProvider { _dateProvider }
    public var sleepProvider: MockSleepProvider { _sleepProvider }
    public var productService: MockProductService { _productService }
    
    /// Reset all mock services to their initial state
    public func resetAll() async {
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
        Container.shared.reset()
    }
}
