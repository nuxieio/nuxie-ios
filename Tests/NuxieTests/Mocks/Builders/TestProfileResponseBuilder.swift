import Foundation
@testable import Nuxie
import FactoryKit

/// Builder for creating test profile responses with fluent API
class TestProfileResponseBuilder {
    private var campaigns: [Campaign] = []
    private var segments: [Segment] = []
    private var flows: [RemoteFlow] = []
    private var userProperties: [String: AnyCodable]?
    private var experimentAssignments: [String: ExperimentAssignment]?
    private var features: [Feature]?

    func withCampaigns(_ campaigns: [Campaign]) -> TestProfileResponseBuilder {
        self.campaigns = campaigns
        return self
    }
    
    func addCampaign(_ campaign: Campaign) -> TestProfileResponseBuilder {
        campaigns.append(campaign)
        return self
    }
    
    func withSegments(_ segments: [Segment]) -> TestProfileResponseBuilder {
        self.segments = segments
        return self
    }
    
    func addSegment(_ segment: Segment) -> TestProfileResponseBuilder {
        segments.append(segment)
        return self
    }
    
    func withFlows(_ flows: [RemoteFlow]) -> TestProfileResponseBuilder {
        self.flows = flows
        return self
    }
    
    func addFlow(_ flow: RemoteFlow) -> TestProfileResponseBuilder {
        flows.append(flow)
        return self
    }
    
    func withUserProperties(_ properties: [String: AnyCodable]) -> TestProfileResponseBuilder {
        self.userProperties = properties
        return self
    }

    func withExperimentAssignments(_ assignments: [String: ExperimentAssignment]) -> TestProfileResponseBuilder {
        self.experimentAssignments = assignments
        return self
    }

    func withFeatures(_ features: [Feature]) -> TestProfileResponseBuilder {
        self.features = features
        return self
    }

    func build() -> ProfileResponse {
        return ProfileResponse(
            campaigns: campaigns,
            segments: segments,
            flows: flows,
            userProperties: userProperties,
            experimentAssignments: experimentAssignments,
            features: features
        )
    }
}