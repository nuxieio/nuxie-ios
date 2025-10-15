import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case flow(String, locale: String? = nil) // flowId
    
    var path: String {
        switch self {
        case .profile:
            return "/api/i/profile"
        case .event:
            return "/api/i/event"
        case .batch:
            return "/api/i/batch"
        case .flow(let flowId, _):
            return "/api/i/flows/\(flowId)"
        }
    }
    
    var method: HTTPMethod {
        switch self {
        case .profile, .event, .batch:
            return .POST
        case .flow:
            return .GET
        }
    }
    
    var authMethod: AuthMethod {
        switch self {
        case .profile, .event, .batch:
            return .apiKeyInBody
        case .flow:
            return .apiKeyInQuery
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .flow(_, let locale):
            if let locale, !locale.isEmpty {
                return [URLQueryItem(name: "locale", value: locale)]
            }
            return nil
        default:
            return nil
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
