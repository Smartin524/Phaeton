import XCTest
@testable import FormatWheelCore

final class WheelGeometryTests: XCTestCase {
    let geometry = WheelGeometry()

    func testThreeSectorCenters() {
        let formats: [OutputFormat] = [.png, .jpeg, .pdf]
        let r = geometry.middleRadius
        XCTAssertEqual(geometry.format(atX: 0, y: -r, in: formats), .png)
        XCTAssertEqual(geometry.format(atX: r * 0.866, y: r * 0.5, in: formats), .jpeg)
        XCTAssertEqual(geometry.format(atX: -r * 0.866, y: r * 0.5, in: formats), .pdf)
    }

    func testTwoAndFiveSectors() {
        let r = geometry.middleRadius
        XCTAssertEqual(geometry.index(atX: 0, y: -r, count: 2), 0)
        XCTAssertEqual(geometry.index(atX: 0, y: r, count: 2), 1)
        XCTAssertEqual(geometry.index(atX: 0, y: -r, count: 5), 0)
        XCTAssertEqual(geometry.index(atX: 0, y: r, count: 5), 2)
    }

    func testCenterOutsideAndInvalidDoNotSelect() {
        XCTAssertNil(geometry.index(atX: 0, y: 0, count: 3))
        XCTAssertNil(geometry.index(atX: 0, y: -200, count: 3))
        XCTAssertNil(geometry.index(atX: .nan, y: 10, count: 3))
        XCTAssertNil(geometry.index(atX: 0, y: -geometry.middleRadius, count: 0))
    }

    func testKindsAndFormats() {
        let png = URL(fileURLWithPath: "/tmp/a.png")
        XCTAssertEqual(FileKind(png), .image)
        XCTAssertEqual(FileKind(URL(fileURLWithPath: "/tmp/a.mov")), .video)
        XCTAssertEqual(FileKind(URL(fileURLWithPath: "/tmp/a.mp3")), .audio)
        XCTAssertEqual(FileKind(URL(fileURLWithPath: "/tmp/a.pdf")), .document)
        XCTAssertNil(FileKind(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertEqual(FileKind.image.outputs(for: [png]), [.jpeg, .pdf])
        XCTAssertEqual(FileKind.document.outputs(for: [URL(fileURLWithPath: "/tmp/a.pdf")]), [.txt])
        XCTAssertEqual(OutputFormat.jpeg.fileExtension, "jpg")
    }
}
