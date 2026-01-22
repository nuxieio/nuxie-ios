import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class TriggerServiceTests: AsyncSpec {
    override class func spec() {
        var mockEventService: MockEventService!
        var mockJourneyService: MockJourneyService!
        var mockFlowPresentationService: MockFlowPresentationService!
        var mockSleepProvider: MockSleepProvider!
        var triggerService: TriggerServiceProtocol!

        beforeEach {
            Container.shared.reset()

            let testConfig = NuxieConfiguration(apiKey: "test-api-key")
            Container.shared.sdkConfiguration.register { testConfig }

            mockEventService = MockEventService()
            mockJourneyService = MockJourneyService()
            mockFlowPresentationService = MockFlowPresentationService()
            mockSleepProvider = MockSleepProvider()
            mockSleepProvider.shouldCompleteImmediately = true

            Container.shared.eventService.register { mockEventService }
            Container.shared.journeyService.register { mockJourneyService }
            Container.shared.flowPresentationService.register { @MainActor in mockFlowPresentationService }
            Container.shared.sleepProvider.register { mockSleepProvider }
            Container.shared.dateProvider.register { MockDateProvider() }
            Container.shared.triggerBroker.register { TriggerBroker() }
            Container.shared.triggerService.register { TriggerService() }

            triggerService = Container.shared.triggerService()
        }

        describe("trigger") {
            it("emits allowedImmediate for allow gate plan") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "allow"
                    ])
                ]
                mockEventService.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    event: EventResponse.EventInfo(id: "event-1", processed: true),
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                    execution: nil
                )

                var updates: [TriggerUpdate] = []

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates).to(contain(.decision(.allowedImmediate)))
            }

            it("emits noMatch when gate plan is missing and no journeys start") {
                mockEventService.trackWithResponseResult = .success()

                var updates: [TriggerUpdate] = []

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates).to(contain(.decision(.noMatch)))
            }

            it("emits journeyStarted when a journey starts") {
                let journey = TestJourneyBuilder().build()
                mockJourneyService.triggerResults = [.started(journey)]
                mockEventService.trackWithResponseResult = .success()

                var updates: [TriggerUpdate] = []

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                expect(updates).to(contain(.decision(.journeyStarted(expectedRef))))
            }

            it("emits entitlement allowed for cache_only gate plan with cached access") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "pro",
                        "policy": "cache_only"
                    ])
                ]
                mockEventService.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    event: EventResponse.EventInfo(id: "event-2", processed: true),
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                    execution: nil
                )

                let info = await MainActor.run { Container.shared.featureInfo() }
                await MainActor.run {
                    info.update([
                        "pro": FeatureAccess.withBalance(1, unlimited: false, type: .metered)
                    ])
                }

                var updates: [TriggerUpdate] = []

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates).to(contain(.entitlement(.allowed(source: .cache))))
            }

            it("emits entitlement denied for cache_only gate plan without access") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "pro",
                        "policy": "cache_only"
                    ])
                ]
                mockEventService.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    event: EventResponse.EventInfo(id: "event-3", processed: true),
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                    execution: nil
                )

                var updates: [TriggerUpdate] = []

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates).to(contain(.entitlement(.denied)))
            }
        }
    }
}
