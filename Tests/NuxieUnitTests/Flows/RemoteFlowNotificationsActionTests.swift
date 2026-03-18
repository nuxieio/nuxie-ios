import XCTest
@testable import Nuxie

final class RemoteFlowNotificationsActionTests: XCTestCase {
    func testDecodesRequestNotificationsAction() throws {
        let data = Data(
            """
            {
              "type": "request_notifications"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(InteractionAction.self, from: data)

        switch action {
        case .requestNotifications(let requestNotifications):
            XCTAssertEqual(requestNotifications.type, "request_notifications")
        default:
            XCTFail("Expected request_notifications action")
        }
    }

    func testEncodesRequestNotificationsAction() throws {
        let action = InteractionAction.requestNotifications(RequestNotificationsAction())

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["type"] as? String, "request_notifications")
    }
}
