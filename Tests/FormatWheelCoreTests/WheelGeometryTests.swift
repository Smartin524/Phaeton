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
        // Five sectors: the third one is centred 54° clockwise from the horizontal axis.
        let angle = 54.0 * .pi / 180
        XCTAssertEqual(geometry.index(atX: r * cos(angle), y: r * sin(angle), count: 5), 2)
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
        XCTAssertEqual(FileKind.image.outputs(for: [png]), [.jpeg, .webp, .heic, .pdf, .txt])
        XCTAssertEqual(FileKind.document.outputs(for: [URL(fileURLWithPath: "/tmp/a.pdf")]), [.png, .jpeg, .txt, .docx])
        XCTAssertEqual(OutputFormat.jpeg.fileExtension, "jpg")
        // Several files at once offer one combined action.
        let pdf = URL(fileURLWithPath: "/tmp/a.pdf")
        XCTAssertEqual(BatchAction.available(kind: .document, urls: [pdf, pdf]), .mergePDFs)
        XCTAssertEqual(BatchAction.available(kind: .image, urls: [png, png]), .mergeImagesToPDF)
        XCTAssertNil(BatchAction.available(kind: .image, urls: [png]))
    }
}
