import XCTest
@testable import IslandCore

final class UsageSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func snapshot(_ text: String) throws -> UsageSnapshot? {
        UsageSnapshot(response: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), fetchedAt: now)
    }
    func testUsesRemainingPercentFromCodexBucketInsteadOfLegacyOrOtherModelBucket() throws {
        let value = try XCTUnwrap(snapshot(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":23,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":95}}}}"#))
        XCTAssertEqual(value.label(at: now), "77%")
        XCTAssertEqual(value.primary.periodLabel, "每周")
    }
    func testMissingPrimaryUsesAvailableSecondaryButMissingUsageNeverBecomesZero() throws {
        let value = try XCTUnwrap(snapshot(#"{"rateLimits":{"primary":null,"secondary":{"usedPercent":10,"windowDurationMins":300}}}"#))
        XCTAssertEqual(value.label(at: now), "90%")
        XCTAssertEqual(value.primary.periodLabel, "5小时")
        XCTAssertNil(try snapshot(#"{"rateLimits":{"primary":{"usedPercent":null},"secondary":null}}"#))
        XCTAssertNil(try snapshot(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":2}}}"#))
    }
    func testDoesNotShowStaleOrResetExpiredQuota() throws {
        let value = try XCTUnwrap(snapshot(#"{"rateLimits":{"primary":{"usedPercent":23,"resetsAt":1100}}}"#))
        XCTAssertEqual(value.label(at: Date(timeIntervalSince1970: 1099)), "77%")
        XCTAssertNil(value.label(at: Date(timeIntervalSince1970: 1100)))
        let noReset = try XCTUnwrap(snapshot(#"{"rateLimits":{"primary":{"usedPercent":23}}}"#))
        XCTAssertNil(noReset.label(at: now.addingTimeInterval(121)))
        XCTAssertNil(noReset.label(at: now.addingTimeInterval(-1)))
    }
    func testBoundsAndFractionalPercentDoNotOverstateRemainingQuota() throws {
        XCTAssertEqual(try snapshot(#"{"rateLimits":{"primary":{"usedPercent":110}}}"#)?.label(at: now), "0%")
        XCTAssertEqual(try snapshot(#"{"rateLimits":{"primary":{"usedPercent":-2}}}"#)?.label(at: now), "100%")
        XCTAssertEqual(try snapshot(#"{"rateLimits":{"primary":{"usedPercent":23.8}}}"#)?.label(at: now), "76%")
    }
}
