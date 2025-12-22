import Foundation
import Quick
import Nimble
@testable import Nuxie

final class UseFeatureTests: AsyncSpec {
    override class func spec() {
        describe("useFeature") {
            var api: NuxieApi!
            var session: URLSession!
            let apiKey = "test-api-key"
            let baseURL = URL(string: "https://test.nuxie.io")!

            beforeEach {
                // Reset protocol handlers
                TestURLSessionProvider.reset()

                // Create test session
                session = TestURLSessionProvider.createNuxieTestSession()

                // Initialize API with test session
                api = NuxieApi(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    useGzipCompression: false,
                    urlSession: session
                )
            }

            afterEach {
                TestURLSessionProvider.reset()
                api = nil
                session = nil
            }

            // MARK: - API Layer Tests

            describe("trackEvent for $feature_used") {
                let distinctId = "user-123"
                let featureId = "ai_generations"

                it("should send correct event data for basic usage") {
                    var capturedRequest: URLRequest?

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["event"] as? String).to(equal("$feature_used"))
                        expect(json["distinct_id"] as? String).to(equal(distinctId))
                        expect(json["value"] as? Double).to(equal(1.0))

                        if let props = json["properties"] as? [String: Any] {
                            expect(props["feature_extId"] as? String).to(equal(featureId))
                        } else {
                            fail("Properties not found in request")
                        }
                    } else {
                        fail("Request body not found or invalid")
                    }
                }

                it("should include entityId when provided") {
                    var capturedRequest: URLRequest?
                    let entityId = "project-456"

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: 1.0,
                        entityId: entityId
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["entityId"] as? String).to(equal(entityId))
                    } else {
                        fail("Request body not found or invalid")
                    }
                }

                it("should send custom amount value") {
                    var capturedRequest: URLRequest?
                    let customAmount = 5.0

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: customAmount,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["value"] as? Double).to(equal(customAmount))
                    } else {
                        fail("Request body not found or invalid")
                    }
                }

                it("should return usage information from response") {
                    let expectedCurrent = 10.0
                    let expectedLimit = 100.0
                    let expectedRemaining = 90.0

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            let response = ResponseBuilders.buildFeatureUsedResponse(
                                current: expectedCurrent,
                                limit: expectedLimit,
                                remaining: expectedRemaining
                            )
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    let result = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(result.status).to(equal("ok"))
                    expect(result.usage).toNot(beNil())
                    expect(result.usage?.current).to(equal(expectedCurrent))
                    expect(result.usage?.limit).to(equal(expectedLimit))
                    expect(result.usage?.remaining).to(equal(expectedRemaining))
                }

                it("should handle network errors") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { _ in throw URLError(.networkConnectionLost) }
                    )

                    do {
                        _ = try await api.trackEvent(
                            event: "$feature_used",
                            distinctId: distinctId,
                            properties: ["feature_extId": featureId],
                            value: 1.0,
                            entityId: nil
                        )
                        fail("Expected to throw URLError")
                    } catch let error as URLError {
                        expect(error.code).to(equal(.networkConnectionLost))
                    } catch {
                        fail("Expected URLError but got \(error)")
                    }
                }

                it("should handle HTTP errors") {
                    let errorResponse = ResponseBuilders.buildErrorResponse(
                        message: "Feature not found"
                    )

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(errorResponse)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 404,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )

                    await expect {
                        try await api.trackEvent(
                            event: "$feature_used",
                            distinctId: distinctId,
                            properties: ["feature_extId": featureId],
                            value: 1.0,
                            entityId: nil
                        )
                    }.to(throwError())
                }
            }

            // MARK: - FeatureUsageResult Tests

            describe("FeatureUsageResult") {
                it("should correctly initialize with all parameters") {
                    let usageInfo = FeatureUsageResult.UsageInfo(
                        current: 10,
                        limit: 100,
                        remaining: 90
                    )

                    let result = FeatureUsageResult(
                        success: true,
                        featureId: "test_feature",
                        amountUsed: 5.0,
                        message: "Usage recorded",
                        usage: usageInfo
                    )

                    expect(result.success).to(beTrue())
                    expect(result.featureId).to(equal("test_feature"))
                    expect(result.amountUsed).to(equal(5.0))
                    expect(result.message).to(equal("Usage recorded"))
                    expect(result.usage).toNot(beNil())
                    expect(result.usage?.current).to(equal(10))
                    expect(result.usage?.limit).to(equal(100))
                    expect(result.usage?.remaining).to(equal(90))
                }

                it("should handle nil usage info") {
                    let result = FeatureUsageResult(
                        success: true,
                        featureId: "test_feature",
                        amountUsed: 1.0,
                        message: nil,
                        usage: nil
                    )

                    expect(result.success).to(beTrue())
                    expect(result.usage).to(beNil())
                    expect(result.message).to(beNil())
                }

                it("should handle unlimited features (nil limit)") {
                    let usageInfo = FeatureUsageResult.UsageInfo(
                        current: 100,
                        limit: nil,
                        remaining: nil
                    )

                    let result = FeatureUsageResult(
                        success: true,
                        featureId: "unlimited_feature",
                        amountUsed: 1.0,
                        message: nil,
                        usage: usageInfo
                    )

                    expect(result.usage?.current).to(equal(100))
                    expect(result.usage?.limit).to(beNil())
                    expect(result.usage?.remaining).to(beNil())
                }

                it("should handle failed usage") {
                    let result = FeatureUsageResult(
                        success: false,
                        featureId: "test_feature",
                        amountUsed: 1.0,
                        message: "Insufficient balance",
                        usage: nil
                    )

                    expect(result.success).to(beFalse())
                    expect(result.message).to(equal("Insufficient balance"))
                }
            }

            // MARK: - Request Property Tests

            describe("setUsage property") {
                let distinctId = "user-123"
                let featureId = "credits"

                it("should include setUsage when true") {
                    var capturedRequest: URLRequest?

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: [
                            "feature_extId": featureId,
                            "setUsage": true
                        ],
                        value: 50.0,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let props = json["properties"] as? [String: Any] {
                        expect(props["setUsage"] as? Bool).to(equal(true))
                    } else {
                        fail("Request body or properties not found")
                    }
                }
            }

            describe("metadata property") {
                let distinctId = "user-123"
                let featureId = "exports"

                it("should include metadata when provided") {
                    var capturedRequest: URLRequest?
                    let metadata: [String: Any] = [
                        "export_type": "pdf",
                        "page_count": 10
                    ]

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: [
                            "feature_extId": featureId,
                            "metadata": metadata
                        ],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let props = json["properties"] as? [String: Any],
                       let receivedMetadata = props["metadata"] as? [String: Any] {
                        expect(receivedMetadata["export_type"] as? String).to(equal("pdf"))
                        expect(receivedMetadata["page_count"] as? Int).to(equal(10))
                    } else {
                        fail("Metadata not found in request")
                    }
                }
            }

            // MARK: - Edge Cases

            describe("edge cases") {
                let distinctId = "user-123"

                it("should handle zero amount") {
                    var capturedRequest: URLRequest?

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse(current: 0)
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": "test"],
                        value: 0.0,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["value"] as? Double).to(equal(0.0))
                    }
                }

                it("should handle fractional amounts") {
                    var capturedRequest: URLRequest?
                    let fractionalAmount = 0.5

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": "test"],
                        value: fractionalAmount,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["value"] as? Double).to(equal(fractionalAmount))
                    }
                }

                it("should handle large amounts") {
                    var capturedRequest: URLRequest?
                    let largeAmount = 999999.99

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": "test"],
                        value: largeAmount,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["value"] as? Double).to(beCloseTo(largeAmount, within: 0.01))
                    }
                }

                it("should handle special characters in featureId") {
                    var capturedRequest: URLRequest?
                    let specialFeatureId = "feature-with_special.chars:v2"

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": specialFeatureId],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let props = json["properties"] as? [String: Any] {
                        expect(props["feature_extId"] as? String).to(equal(specialFeatureId))
                    }
                }

                it("should handle special characters in entityId") {
                    var capturedRequest: URLRequest?
                    let specialEntityId = "org:123/project:456"

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            capturedRequest = request

                            let response = ResponseBuilders.buildFeatureUsedResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": "test"],
                        value: 1.0,
                        entityId: specialEntityId
                    )

                    expect(capturedRequest).toNot(beNil())

                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["entityId"] as? String).to(equal(specialEntityId))
                    }
                }
            }

            // MARK: - Response Status Variations

            describe("response status handling") {
                let distinctId = "user-123"
                let featureId = "test_feature"

                it("should recognize 'ok' as success") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            let response = ResponseBuilders.buildFeatureUsedResponse(status: "ok")
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    let result = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(result.status).to(equal("ok"))
                }

                it("should recognize 'success' as success") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/api/i/event"),
                        handler: { request in
                            let response = ResponseBuilders.buildFeatureUsedResponse(status: "success")
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    let result = try await api.trackEvent(
                        event: "$feature_used",
                        distinctId: distinctId,
                        properties: ["feature_extId": featureId],
                        value: 1.0,
                        entityId: nil
                    )

                    expect(result.status).to(equal("success"))
                }
            }
        }
    }
}
