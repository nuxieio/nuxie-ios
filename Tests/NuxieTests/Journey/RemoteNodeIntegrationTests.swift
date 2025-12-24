import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class RemoteNodeIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Remote Node Execution") {
            var executor: JourneyExecutor!
            var mockEventService: JourneyExecutorTestEventService!
            var mockDateProvider: MockDateProvider!
            var journey: Journey!
            var campaign: Campaign!

            beforeEach {

                // Register test configuration (required for any services that depend on sdkConfiguration)
                let testConfig = NuxieConfiguration(apiKey: "test-api-key")
                Container.shared.sdkConfiguration.register { testConfig }

                // Create mock services
                mockEventService = JourneyExecutorTestEventService()
                mockDateProvider = MockDateProvider()
                mockDateProvider.setCurrentDate(Date(timeIntervalSince1970: 1000))

                // Register mocks with DI container
                Container.shared.eventService.register { mockEventService }
                Container.shared.dateProvider.register { mockDateProvider }
                Container.shared.flowService.register { JourneyExecutorTestFlowService() }
                Container.shared.identityService.register { JourneyExecutorTestIdentityService() }
                Container.shared.segmentService.register { JourneyExecutorTestSegmentService() }

                // Create executor
                executor = JourneyExecutor()

                // Build test campaign with remote node
                let remoteNode = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                    .withNext(["exit-1"])
                    .build()

                let exitNode = TestNodeBuilder.exit(id: "exit-1").build()

                campaign = TestCampaignBuilder()
                    .withId("test-campaign")
                    .withName("Test Campaign")
                    .withNodes([remoteNode, exitNode])
                    .withEntryNodeId("remote-1")
                    .build()

                journey = Journey(campaign: campaign, distinctId: "user-1")
            }

            afterEach {
                mockEventService?.reset()
                // Don't reset container here - let beforeEach handle it
                // to avoid race conditions with background tasks accessing services
            }

            // MARK: - Synchronous Mode Tests

            context("synchronous mode (default)") {
                it("continues to next node on successful execution") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseResult = .withExecution(success: true)

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(result).to(equal(.continue(["next-node"])))
                    expect(mockEventService.trackWithResponseCalls).to(haveCount(1))
                    expect(mockEventService.trackWithResponseCalls.first?.event).to(equal("$journey_node_executed"))
                }

                it("applies context updates from server response") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseResult = .withExecution(
                        success: true,
                        contextUpdates: [
                            "discount": AnyCodable(0.2),
                            "couponCode": AnyCodable("SAVE20")
                        ]
                    )

                    // When
                    _ = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(journey.getContext("discount") as? Double).to(equal(0.2))
                    expect(journey.getContext("couponCode") as? String).to(equal("SAVE20"))
                }

                it("schedules retry on retryable error") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseResult = .withRetryableError(retryAfter: 10)

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    if case .async(let resumeAt) = result {
                        // Should schedule retry 10 seconds from now (1000 + 10 = 1010)
                        expect(resumeAt?.timeIntervalSince1970).to(equal(1010))
                    } else {
                        fail("Expected .async result, got \(result)")
                    }
                }

                it("completes with error on non-retryable error") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseResult = .withNonRetryableError(message: "Invalid payload")

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(result).to(equal(.complete(.error)))
                }

                it("schedules retry on network error") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseError = URLError(.notConnectedToInternet)

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    if case .async(let resumeAt) = result {
                        // Should schedule retry 5 seconds from now (default retry interval)
                        expect(resumeAt?.timeIntervalSince1970).to(equal(1005))
                    } else {
                        fail("Expected .async result for network error, got \(result)")
                    }
                }

                it("sends correct event properties") {
                    // Given
                    journey.setContext("userId", value: "u123")

                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withRemotePayload(["key": "value"])
                        .withNext(["next-node"])
                        .build()

                    mockEventService.trackWithResponseResult = .withExecution(success: true)

                    // When
                    _ = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(mockEventService.trackWithResponseCalls).to(haveCount(1))
                    let call = mockEventService.trackWithResponseCalls.first
                    expect(call?.properties?["session_id"] as? String).to(equal(journey.id))
                    expect(call?.properties?["node_id"] as? String).to(equal("remote-1"))
                }

                it("continues when no execution result in response") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext(["next-node"])
                        .build()

                    // Response with no execution result
                    mockEventService.trackWithResponseResult = .success()

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(result).to(equal(.continue(["next-node"])))
                }
            }

            // MARK: - Async Mode Tests

            context("async mode (fire-and-forget)") {
                it("fires event and continues immediately without waiting") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook", async: true)
                        .withNext(["next-node"])
                        .build()

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(result).to(equal(.continue(["next-node"])))
                    // Should use regular track, not trackWithResponse
                    expect(mockEventService.trackedEvents).to(haveCount(2)) // node_executed + the async event
                    expect(mockEventService.trackWithResponseCalls).to(haveCount(0))
                }

                it("sends correct event for async mode") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "slack", async: true)
                        .withRemotePayload(["channel": "#alerts"])
                        .withNext(["next-node"])
                        .build()

                    // When
                    _ = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    // Find the async remote event (not the node_executed tracking event)
                    let asyncEvent = mockEventService.trackedEvents.first { $0.name == "$journey_node_executed" }
                    expect(asyncEvent).toNot(beNil())
                    expect(asyncEvent?.properties?["session_id"] as? String).to(equal(journey.id))
                }
            }

            // MARK: - Edge Cases

            context("edge cases") {
                it("handles empty next array") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .withNext([])
                        .build()

                    mockEventService.trackWithResponseResult = .withExecution(success: true)

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    expect(result).to(equal(.continue([])))
                }

                it("uses default retry interval when retryAfter not specified") {
                    // Given
                    let node = TestNodeBuilder.remote(id: "remote-1", action: "webhook")
                        .build()

                    // Retryable error without specific retryAfter
                    mockEventService.trackWithResponseResult = EventResponse(
                        status: "ok",
                        payload: nil,
                        customer: nil,
                        event: nil,
                        message: nil,
                        featuresMatched: nil,
                        usage: nil,
                        journey: nil,
                        execution: EventResponse.ExecutionResult(
                            success: false,
                            statusCode: 503,
                            error: EventResponse.ExecutionResult.ExecutionError(
                                message: "Unavailable",
                                retryable: true,
                                retryAfter: nil
                            ),
                            contextUpdates: nil
                        )
                    )

                    // When
                    let result = await executor.executeNode(node.node, journey: journey, resumeReason: .start)

                    // Then
                    if case .async(let resumeAt) = result {
                        // Default retry is 5 seconds
                        expect(resumeAt?.timeIntervalSince1970).to(equal(1005))
                    } else {
                        fail("Expected .async result")
                    }
                }
            }
        }
    }
}
