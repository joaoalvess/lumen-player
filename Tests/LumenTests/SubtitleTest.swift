@testable import Lumen
import XCTest

private final class StubSubtitleInfo: SubtitleInfo {
    let subtitleID = "stub"
    let name = "stub"
    var delay: TimeInterval = 0
    var isEnabled = false
    var parts = [SubtitlePart]()

    func search(for _: TimeInterval) -> [SubtitlePart] {
        parts
    }
}

class SubtitleTest: XCTestCase {
    func testEmbeddedSubtitleCanBeRepublishedAfterURLResetWithoutDuplicates() {
        let model = SubtitleModel()
        let info = StubSubtitleInfo()
        model.addSubtitle(info: info)
        XCTAssertEqual(model.subtitleInfos.count, 1)

        model.url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mkv")
        XCTAssertTrue(model.subtitleInfos.isEmpty)

        model.addSubtitle(info: info)
        model.addSubtitle(info: info)
        XCTAssertEqual(model.subtitleInfos.count, 1)
        XCTAssertTrue(model.subtitleInfos.first.map { $0 === info } ?? false)
    }

    func testSrt() {
        let string = """
        1
        00:00:00,050 --> 00:00:11,000
        <font color="#4096d1">本字幕仅供学习交流，严禁用于商业用途</font>

        2
        00:00:13,000 --> 00:00:18,000
        <font color=#4096d1>-=破烂熊字幕组=-
        翻译:风铃
        校对&时间轴:小白</font>

        3
        00:01:00,840 --> 00:01:02,435
        你现在必须走了吗?

        4
        00:01:02,680 --> 00:01:04,318
        我说过我会去找他的

        5
        00:01:07,194 --> 00:01:08,239
        - 很多事情我们都说过
        - 我承诺过他

        907
        00:59:47,520 --> 00:59:49,720
        有两个人在我们镇上
        There were two men in my hometown

        908
        00:59:51,370 --> 00:59:55,170
        被判4F不合格，他们就自杀了，因为不能服役
        Declared 4-F unfit, they killed themselves cause they couldn't serve.

        909
        00:59:55,750 --> 00:59:58,360
        注：4-F，二战服役有关的物理，心理，或道德标准。
        https://en.wikipedia.org/wiki/Selective_Service_System

         http://www.apd.army.mil/pdffiles/r40_501.pdf

        910
        00:59:59,220 --> 01:00:01,140
        为何？我在国防工厂有份工作
        Why, I had a job in a defense plant.

        """
        let scanner = Scanner(string: string)
        let parse = SrtParse()
        XCTAssertEqual(parse.canParse(scanner: scanner), true)
        let parts = parse.parse(scanner: scanner)
        XCTAssertEqual(parts.count, 9)
        XCTAssertEqual(parts[8].end, 3601.14)
    }

    func testVtt() {
        let string = """
        WEBVTT
        1
        00:00:00,050 --> 00:00:11,000
        <font color="#4096d1">本字幕仅供学习交流，严禁用于商业用途</font>

        2
        00:00:13,000 --> 00:00:18,000
        <font color=#4096d1>-=破烂熊字幕组=-
        翻译:风铃
        校对&时间轴:小白</font>

        3
        00:01:00,840 --> 00:01:02,435
        你现在必须走了吗?

        4
        00:01:02,680 --> 00:01:04,318
        我说过我会去找他的

        5
        00:01:07,194 --> 00:01:08,239
        - 很多事情我们都说过
        - 我承诺过他

        6
        00:01:08,280 --> 00:01:10,661
        我希望你明白

        7
        00:01:12,814 --> 00:01:14,702
        等等! 你是不可能活着回来的!

        """
        let scanner = Scanner(string: string)
        let parse = VTTParse()
        XCTAssertEqual(parse.canParse(scanner: scanner), true)
        let parts = parse.parse(scanner: scanner)
        XCTAssertEqual(parts.count, 7)
    }

    func testAssFontScale() {
        XCTAssertEqual(AssParse.fontScale(playResY: 288, preferredSize: 58), 58.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(AssParse.fontScale(playResY: 720, preferredSize: 58), (58.0 / 16.0) * (288.0 / 720.0), accuracy: 0.0001)
        XCTAssertEqual(AssParse.fontScale(playResY: 0, preferredSize: 58), 58.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(AssParse.fontScale(playResY: -10, preferredSize: 58), 58.0 / 16.0, accuracy: 0.0001)
    }

    func testAssStyleFontScaledByPlayRes() throws {
        let string = """
        [Script Info]
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,16

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello

        """
        let scanner = Scanner(string: string)
        let parse = AssParse()
        XCTAssertEqual(parse.canParse(scanner: scanner), true)
        let parts = parse.parse(scanner: scanner)
        XCTAssertEqual(parts.count, 1)
        let text = try XCTUnwrap(parts[0].text)
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, SubtitleModel.textFontSize, accuracy: 0.01)
    }

    func testSrtKeepsPerRunFontEmpty() throws {
        let string = """
        1
        00:00:00,050 --> 00:00:01,000
        Hello

        """
        let scanner = Scanner(string: string)
        let parse = SrtParse()
        XCTAssertEqual(parse.canParse(scanner: scanner), true)
        let parts = parse.parse(scanner: scanner)
        XCTAssertEqual(parts.count, 1)
        let text = try XCTUnwrap(parts[0].text)
        XCTAssertNil(text.attribute(.font, at: 0, effectiveRange: nil))
    }

    func testParseDurationReadsTheFractionByItsDigitCount() {
        let cases: [(String, TimeInterval)] = [
            ("0:12:37.73", 757.73),
            ("0:12:37.7", 757.7),
            ("0:12:37.730", 757.73),
            ("0:12:37", 757),
            (" 0:12:38.83", 758.83),
            ("0:30:11.56", 1811.56),
            ("00:12:37,184", 757.184),
            ("00:12:37,18", 757.18),
            ("00:12:37,1", 757.1),
            ("00:12:37", 757),
            ("01:00:01,140", 3601.14),
            ("00:00:00,050", 0.05),
            (" 00:00:53,617", 53.617),
            ("00:12:37.184", 757.184),
            ("00:00.430", 0.43),
            ("00:03.380", 3.38),
        ]
        for (string, expected) in cases {
            XCTAssertEqual(string.parseDuration(), expected, accuracy: 0.0005, string)
        }
    }

    func testTickKeepsTheFontTheParserSet() throws {
        let parsedFont = UIFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "Hello")
        text.addAttribute(.font, value: parsedFont, range: NSRange(location: 0, length: text.length))
        let info = StubSubtitleInfo()
        info.parts = [SubtitlePart(0, 10, attributedString: text)]
        let model = SubtitleModel()
        model.selectedSubtitleInfo = info
        XCTAssertEqual(model.subtitle(currentTime: 1), true)
        XCTAssertEqual(model.parts.count, 1)
        let displayed = try XCTUnwrap(model.parts[0].text)
        let font = try XCTUnwrap(displayed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(font.fontName, parsedFont.fontName)
    }

    func testTickFillsTheGlobalFontWhenTheParserSetNone() throws {
        let text = NSMutableAttributedString(string: "Hello")
        let info = StubSubtitleInfo()
        info.parts = [SubtitlePart(0, 10, attributedString: text)]
        let model = SubtitleModel()
        model.selectedSubtitleInfo = info
        XCTAssertEqual(model.subtitle(currentTime: 1), true)
        XCTAssertEqual(model.parts.count, 1)
        let displayed = try XCTUnwrap(model.parts[0].text)
        let font = try XCTUnwrap(displayed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, SubtitleModel.textFontSize, accuracy: 0.01)
    }

    func testTickFillsOnlyTheRunsWithoutFont() throws {
        let parsedFont = UIFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "Styled")
        text.addAttribute(.font, value: parsedFont, range: NSRange(location: 0, length: text.length))
        let plainLocation = text.length
        text.append(NSAttributedString(string: "Plain"))
        let info = StubSubtitleInfo()
        info.parts = [SubtitlePart(0, 10, attributedString: text)]
        let model = SubtitleModel()
        model.selectedSubtitleInfo = info
        XCTAssertEqual(model.subtitle(currentTime: 1), true)
        XCTAssertEqual(model.parts.count, 1)
        let displayed = try XCTUnwrap(model.parts[0].text)
        let styledFont = try XCTUnwrap(displayed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(styledFont.pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(styledFont.fontName, parsedFont.fontName)
        let plainFont = try XCTUnwrap(displayed.attribute(.font, at: plainLocation, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(plainFont.pointSize, SubtitleModel.textFontSize, accuracy: 0.01)
    }

    func testTickKeepsTheAssHeaderAndInlineFonts() throws {
        let string = """
        [Script Info]
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Helvetica,32

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Plain
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\fnCourier\\fs30}Inline

        """
        let scanner = Scanner(string: string)
        let parse = AssParse()
        XCTAssertEqual(parse.canParse(scanner: scanner), true)
        let parts = parse.parse(scanner: scanner)
        XCTAssertEqual(parts.count, 2)
        let parsedHeader = try XCTUnwrap(parts[0].text)
        let parsedHeaderFont = try XCTUnwrap(parsedHeader.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let parsedInline = try XCTUnwrap(parts[1].text)
        let parsedInlineFont = try XCTUnwrap(parsedInline.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let info = StubSubtitleInfo()
        info.parts = parts
        let model = SubtitleModel()
        model.selectedSubtitleInfo = info
        XCTAssertEqual(model.subtitle(currentTime: 1.5), true)
        XCTAssertEqual(model.parts.count, 2)
        let displayedHeader = try XCTUnwrap(model.parts[0].text)
        let headerFont = try XCTUnwrap(displayedHeader.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(headerFont.fontName, parsedHeaderFont.fontName)
        XCTAssertEqual(headerFont.pointSize, 32 * SubtitleModel.textFontSize / 16, accuracy: 0.01)
        let displayedInline = try XCTUnwrap(model.parts[1].text)
        let inlineFont = try XCTUnwrap(displayedInline.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(inlineFont.fontName, parsedInlineFont.fontName)
        XCTAssertEqual(inlineFont.pointSize, 30 * SubtitleModel.textFontSize / 16, accuracy: 0.01)
    }
}
