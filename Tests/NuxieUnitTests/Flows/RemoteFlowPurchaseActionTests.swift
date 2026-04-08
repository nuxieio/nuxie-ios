import XCTest
@testable import Nuxie

final class RemoteFlowPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseActionWithValueRefs() throws {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementIndex": {
                "ref": {
                  "kind": "ids",
                  "pathIds": [3893745128, 10, 8]
                }
              },
              "productId": {
                "ref": {
                  "kind": "ids",
                  "pathIds": [3893745128, 10, 9]
                }
              }
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(InteractionAction.self, from: data)

        switch action {
        case .purchase(let purchase):
            XCTAssertEqual(purchase.type, "purchase")
            XCTAssertEqual(
                purchase.placementIndex,
                AnyCodable([
                    "ref": [
                        "kind": "ids",
                        "pathIds": [3893745128, 10, 8],
                    ],
                ])
            )
            XCTAssertEqual(
                purchase.productId,
                AnyCodable([
                    "ref": [
                        "kind": "ids",
                        "pathIds": [3893745128, 10, 9],
                    ],
                ])
            )
        default:
            XCTFail("Expected purchase action")
        }
    }

    func testPurchaseActionRequiresProductId() {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementIndex": {
                "ref": {
                  "kind": "ids",
                  "pathIds": [3893745128, 10, 8]
                }
              }
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
              "productId": {
                "ref": {
                  "kind": "ids",
                  "pathIds": [3893745128, 10, 9]
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(InteractionAction.self, from: data))
    }
}
