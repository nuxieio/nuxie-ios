import Foundation
@testable import Nuxie
import FactoryKit

/// Builder for creating test journeys with fluent API
class TestJourneyBuilder {
    private var id: String
    private var campaign: Campaign
    private var distinctId: String
    private var status: JourneyStatus
    private var currentNodeId: String?
    private var context: [String: AnyCodable]
    private var resumeAt: Date?
    private var startedAt: Date
    private var completedAt: Date?
    private var exitReason: JourneyExitReason?
    
    init(id: String = "test-journey") {
        self.id = id
        // Create a default campaign
        self.campaign = TestCampaignBuilder(id: "test-campaign").build()
        self.distinctId = "test-user"
        self.status = .active
        self.currentNodeId = nil
        self.context = [:]
        self.resumeAt = nil
        self.startedAt = Date()
        self.completedAt = nil
        self.exitReason = nil
    }
    
    func withId(_ id: String) -> TestJourneyBuilder {
        self.id = id
        return self
    }
    
    func withCampaign(_ campaign: Campaign) -> TestJourneyBuilder {
        self.campaign = campaign
        return self
    }
    
    func withCampaignId(_ campaignId: String) -> TestJourneyBuilder {
        self.campaign = TestCampaignBuilder(id: campaignId).build()
        return self
    }
    
    func withDistinctId(_ distinctId: String) -> TestJourneyBuilder {
        self.distinctId = distinctId
        return self
    }
    
    func withStatus(_ status: JourneyStatus) -> TestJourneyBuilder {
        self.status = status
        return self
    }
    
    func withCurrentNodeId(_ nodeId: String?) -> TestJourneyBuilder {
        self.currentNodeId = nodeId
        return self
    }
    
    func withContext(_ context: [String: AnyCodable]) -> TestJourneyBuilder {
        self.context = context
        return self
    }
    
    func withResumeAt(_ date: Date?) -> TestJourneyBuilder {
        self.resumeAt = date
        return self
    }
    
    func withStartedAt(_ date: Date) -> TestJourneyBuilder {
        self.startedAt = date
        return self
    }
    
    func withCompletedAt(_ date: Date?) -> TestJourneyBuilder {
        self.completedAt = date
        return self
    }
    
    func withExitReason(_ reason: JourneyExitReason?) -> TestJourneyBuilder {
        self.exitReason = reason
        return self
    }
    
    func build() -> Journey {
        return Journey(campaign: campaign, distinctId: distinctId)
    }
}