import XCTest
@testable import FormatWheelCore

final class PDFToolsTests: XCTestCase {
    func testPageRanges() throws {
        XCTAssertEqual(try PDFTools.parsePages("1-3,5", pageCount: 9), [0, 1, 2, 4])
        XCTAssertEqual(try PDFTools.parsePages(" 2 ， 4 ", pageCount: 9), [1, 3])       // Chinese comma, spaces
        XCTAssertEqual(try PDFTools.parsePages("1－2", pageCount: 3), [0, 1])           // full-width dash
        XCTAssertEqual(try PDFTools.parsePages("3,1", pageCount: 3), [2, 0])           // order is kept
        XCTAssertEqual(try PDFTools.parsePages("1,,", pageCount: 3), [0])              // stray commas are ignored
    }

    func testInvalidPageRangesAreRefused() {
        for text in ["", "3-", "-3", "0", "4", "2-1", "1-4", "a", "1-2-3"] {
            XCTAssertThrowsError(try PDFTools.parsePages(text, pageCount: 3), "\"\(text)\" should be refused")
        }
    }

    func testServiceUsesTheSameRules() throws {
        let service = ConversionService()
        XCTAssertNoThrow(try service.validatePages("1-2", pageCount: 3))
        XCTAssertThrowsError(try service.validatePages("3-", pageCount: 3))
    }
}
