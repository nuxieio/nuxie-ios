import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case flow(String) // flowId
    case checkFeature(FeatureCheckRequest)

    var path: String {
        switch self {
        case .profile:
            return "/api/i/profile"
        case .event:
            return "/api/i/event"
        case .batch:
            return "/api/i/batch"
        case .flow(let flowId):
            return "/api/i/flows/\(flowId)"
        case .checkFeature:
            return "/api/i/entitled"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature:
            return .POST
        case .flow:
            return .GET
        }
    }

    var authMethod: AuthMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature:
            return .apiKeyInBody
        case .flow:
            return .apiKeyInQuery
        }
    }
}

enum HTTPMethod: String {
    case GET = "GET"
    case POST = "POST"
}

enum AuthMethod {
    case apiKeyInBody
    case apiKeyInQuery
}
