import XCTest
@testable import Nuxie

final class RemoteFlowPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseAction() throws {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementIndex": 0,
              "productId": "prod_yearly"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(InteractionAction.self, from: data)

        switch action {
        case .purchase(let purchase):
            XCTAssertEqual(purchase.type, "purchase")
            XCTAssertEqual(purchase.productId.value as? String, "prod_yearly")
            XCTAssertEqual(purchase.placementIndex.value as? Int, 0)
        default:
            XCTFail("Expected purchase action")
        }
    }

    func testPurchaseActionRequiresProductId() {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementIndex": 0
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(InteractionAction.self, from: data))
    }

    func testPurchaseActionRequiresPlacementIndex() {
        let data = Data(
            """
            {
              "type": "purchase",
              "productId": "prod_yearly"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(InteractionAction.self, from: data))
    }
}
