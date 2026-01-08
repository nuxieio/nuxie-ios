import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case flow(String) // flowId
    case checkFeature(FeatureCheckRequest)
    case purchase(PurchaseRequest)

    var path: String {
        switch self {
        case .profile:
            return "/profile"
        case .event:
            return "/event"
        case .batch:
            return "/batch"
        case .flow(let flowId):
            return "/flows/\(flowId)"
        case .checkFeature:
            return "/entitled"
        case .purchase:
            return "/purchase"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature, .purchase:
            return .POST
        case .flow:
            return .GET
        }
    }

    var authMethod: AuthMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature, .purchase:
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
