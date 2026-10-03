import AppKit
import XCTest
@testable import FormatWheelCore

final class MarkdownTests: XCTestCase {
    func testInlineMergesStylesAndKeepsSpacesOutsideMarkers() {
        let spans = [MarkdownSpan(text: "这是"), MarkdownSpan(text: "加粗 ", bold: true), MarkdownSpan(text: "文字", bold: true),
                     MarkdownSpan(text: "和"), MarkdownSpan(text: "链接", link: "https://example.com"),
                     MarkdownSpan(text: "a*b_c"), MarkdownSpan(text: "x`y", code: true)]
        XCTAssertEqual(MarkdownBuilder.inline(spans), "这是**加粗 文字**和[链接](https://example.com)a\\*b\\_c`` x`y ``")
        XCTAssertEqual(MarkdownBuilder.inline([MarkdownSpan(text: " 粗 ", bold: true)]), " **粗** ")
    }

    func testBlocksListsAndTables() {
        var md = MarkdownBuilder()
        md.heading(2, [MarkdownSpan(text: "标题", bold: true)])
        md.paragraph([MarkdownSpan(text: "# 不是标题")])
        md.listItem(level: 0, marker: "-", [MarkdownSpan(text: "一")])
        md.listItem(level: 1, marker: "-", [MarkdownSpan(text: "二")])
        md.listItem(level: 0, marker: "1.", [MarkdownSpan(text: "三")])
        md.table([["名称", "说明"], ["A|B", "第一行\n第二行"]])
        XCTAssertEqual(md.text, """
        ## 标题

        \\# 不是标题

        - 一
            - 二

        1. 三

        | 名称 | 说明 |
        | --- | --- |
        | A\\|B | 第一行<br>第二行 |

        """)
    }

    func testListsTypedAsText() {
        XCTAssertEqual(MarkdownBuilder.textListMarker("\t•\t项目")?.marker, "-")
        XCTAssertEqual(MarkdownBuilder.textListMarker("\t◦\t项目")?.level, 1)
        XCTAssertEqual(MarkdownBuilder.textListMarker("\t3\t项目")?.marker, "3.")
        XCTAssertNil(MarkdownBuilder.textListMarker("2024 年总结"))      // a number with a space is just text
    }

    func testRichTextKeepsStructure() {
        let para = NSMutableParagraphStyle()
        para.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        let text = NSMutableAttributedString(string: "大标题\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        text.append(NSAttributedString(string: "正文内容，比较长的一段文字。\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        text.append(NSAttributedString(string: "第一步\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: para]))
        text.append(NSAttributedString(string: "第二步\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: para]))
        XCTAssertEqual(AttributedMarkdown.convert(text), "# 大标题\n\n正文内容，比较长的一段文字。\n\n1. 第一步\n2. 第二步\n")
    }

    func testMarkdownIsReadAsFormatting() {
        let text = MarkdownReader.attributedString(from: "# 标题\n\n**粗**和[链接](https://example.com)\n\n- 项目\n")
        XCTAssertFalse(text.string.contains("#"))
        XCTAssertFalse(text.string.contains("**"))
        XCTAssertTrue(text.string.contains("•\t项目"))
        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(heading?.pointSize ?? 0, 18)
        let link = (text.string as NSString).range(of: "链接")
        XCTAssertNotNil(text.attribute(.link, at: link.location, effectiveRange: nil))
    }
}
