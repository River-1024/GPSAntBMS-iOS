import XCTest
@testable import GPSAntBMS

final class AppVersionHistoryTests: XCTestCase {
    func testValidHistoryPreservesNewestFirstOrder() throws {
        let history = try AppVersionHistory(data: validData)

        XCTAssertEqual(history.releases.map(\.version), ["1.2.0", "1.1.0", "1.0.0"])
        let releaseDate = try XCTUnwrap(history.releases.first?.parsedReleaseDate)
        XCTAssertEqual(releaseDate.timeIntervalSince1970, 1_735_689_600, accuracy: 0.1)
    }

    func testRejectsMalformedDate() {
        XCTAssertThrowsError(try history(replacing: "2025-01-01", with: "2025/01/01"))
    }

    func testRejectsNonexistentDate() {
        XCTAssertThrowsError(try history(replacing: "2025-01-01", with: "2025-02-30"))
    }

    func testRejectsDuplicateVersion() {
        XCTAssertThrowsError(try history(replacing: "1.1.0", with: "1.2.0"))
    }

    func testRejectsOutOfOrderVersion() {
        XCTAssertThrowsError(try history(replacing: "1.1.0", with: "1.3.0"))
    }

    func testRejectsEmptyChangeList() {
        let data = Data("""
        {"releases":[{"version":"1.0.0","build":"1","releaseDate":"2025-01-01","changes":[]}]}
        """.utf8)

        XCTAssertThrowsError(try AppVersionHistory(data: data))
    }

    func testRequiresCurrentVersionAndBuildToHaveAReleaseEntry() throws {
        let history = try AppVersionHistory(data: validData)

        XCTAssertNoThrow(try history.validate(currentVersion: "1.2.0", build: "3"))
        XCTAssertThrowsError(try history.validate(currentVersion: "1.2.0", build: "4"))
    }

    private var validData: Data {
        Data("""
        {"releases":[
          {"version":"1.2.0","build":"3","releaseDate":"2025-01-01","changes":["最新改动"]},
          {"version":"1.1.0","build":"2","releaseDate":"2024-12-01","changes":["上一版改动"]},
          {"version":"1.0.0","build":"1","releaseDate":"2024-11-01","changes":["首版"]}
        ]}
        """.utf8)
    }

    private func history(replacing original: String, with replacement: String) throws -> AppVersionHistory {
        let json = String(decoding: validData, as: UTF8.self)
            .replacingOccurrences(of: original, with: replacement)
        return try AppVersionHistory(data: Data(json.utf8))
    }
}
