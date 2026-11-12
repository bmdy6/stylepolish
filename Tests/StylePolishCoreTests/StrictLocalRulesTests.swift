import XCTest
import StylePolishCore

// Historical run-strict.py (30) and run.py (39) evaluation inputs.
enum LocalRuleFixtures {
    static let strictBad = [
        "这也是一个差异化",
        "这个也算一个优化",
        "这也是一个改进",
        "明天的话我应该能弄完",
        "就是我觉得这个方案其实还可以吧",
        "然后那个文件我已经发你了",
        "其实我想说的是这个价格有点高",
        "买点水果啥的",
        "带个充电器什么的",
        "我那个昨天就是去了一趟银行然后办了个卡",
        "这个接口的话现在是有点慢的然后我想加个缓存你觉得呢",
        "虽然成本高，我们还是要做",
        "一张会议纪要我发群里了",
        "我们先把登录做了然后支付那个等下周再说因为第三方还没给文档",
        "因为这个原因所以我们就是说要先停一下",
    ]
    static let strictOk = [
        "好的，我晚点看一下",
        "我在路上了",
        "那个文件发我一下",
        "啥时候到啊",
        "收到",
        "先开会，然后再定方案",
        "如果明天下雨的话就改期",
        "这个价格有点高",
        "我觉得还行",
        "你看看呢",
        "周五那个会能不能改到下周一",
        "文件我已经发你了",
        "买点水果",
        "这是个优化点",
        "大白兔奶糖12块一袋",
    ]
    static let standardBad = [
        "这也是一个差异化",
        "通过这次活动，使我明白了很多",
        "我们要提高产品的质量和数量增加",
        "他的建议被大家所采纳了意见",
        "大约有十个左右的人会来",
        "能不能做好关键在于努力",
        "我把文件已经发了给你",
        "为了防止不再出错，我加了个检查",
        "这个方案的优点是成本低是它的优点",
        "我昨天去超市买东西了很多",
        "这个功能对用户的体验有很大的提高了帮助",
        "由于时间的原因的关系，我先不改了",
        "他们对这个结果表示很满意的态度",
        "这个数据显示出了增长的趋势在上升",
        "这个也算一个优化",
        "这是我们的一个核心竞争",
        "他这个人最大的就是太急",
        "这个设计的合理还要再看看",
        "是否上线取决于测试通过",
    ]
    static let standardOk = [
        "好的，我晚点看一下",
        "我在路上了",
        "那个文件发我一下",
        "大白兔奶糖12块一袋",
        "啥时候到啊",
        "你看看呢",
        "先这样吧",
        "我觉得还行",
        "周五那个会能不能改到下周一",
        "明天的话我应该能弄完",
        "这个功能还在开发",
        "就当请你吃饭了，毕竟上班你还帮了我这么多",
        "这也是一个差异化的点",
        "我先看看，有问题再找你",
        "这个也算一个优化点",
        "这个做得挺好的",
        "最大的问题是没时间",
        "这是个优化",
        "稳定性还不够",
        "这个太急了",
    ]
}

final class StrictLocalRulesTests: XCTestCase {
    private let hardNegatives = [
        "先登录，然后打开设置", "我们先吃饭然后去散步", "先保存文件，然后关闭窗口",
        "先确认需求然后再写代码", "先洗手然后吃饭", "先选日期，然后选择时间",
        "如果有空的话就过来", "要是明天下雨的话就延期", "假如测试通过的话就发布",
        "如果你觉得合适，明天的话也可以", "要是那个文件找不到的话就问我",
        "假如先到的话就等一会", "可以的话请回复", "我没记错的话就是周五",
        "那个文件发我一下", "这个方案已经定了", "周五那个会改到周一",
        "那个接口已经修好了", "这个问题已经解决了", "那个同事明天过来"
    ]
    func testStrictFillersAndVagueEndings() {
        for (text, word) in [
            ("就是我觉得这个方案还可以吧", "就是"), ("其实我想说的是这个价格有点高", "其实"),
            ("然后那个文件我已经发你了", "然后"), ("明天的话我应该能弄完", "的话"),
            ("我那个昨天去了一趟银行", "那个"), ("买点水果啥的", "啥的"),
            ("带个充电器什么的。", "什么的"), ("买个本子之类的！", "之类的")
        ] {
            let edits = LocalRules.check(text, level: .strict)
            XCTAssertTrue(edits.contains { $0.original == word && $0.replacement.isEmpty && $0.kind == .filler }, text)
            XCTAssertTrue(LocalRules.check(text, level: .standard).isEmpty, text)
            XCTAssertTrue(LocalRules.check(text, level: .relaxed).isEmpty, text)
        }
    }
    func testTwentyHardNegativesAndCompleteRepliesStayUntouched() {
        XCTAssertEqual(hardNegatives.count, 20)
        for text in hardNegatives + ["好的", "收到", "我在路上了", "原因就是这个", "其实不然", "什么的意思", "水果啥的都可以买", "先开会。然后再定方案", "然后再定方案", "然后呢", "明天的话题我准备好了", "这段说明名副其实还可以", "我们说的那个我也记得"] {
            XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
        }
    }
    func testHistoricalFixturesHaveNoFalsePositivesAndReportCoverage() {
        for (name, level, bad, ok) in [("strict", Strictness.strict, LocalRuleFixtures.strictBad, LocalRuleFixtures.strictOk),
                                ("standard-history", Strictness.standard, LocalRuleFixtures.standardBad, LocalRuleFixtures.standardOk)] {
            let hits = bad.filter { !LocalRules.check($0, level: level).isEmpty }
            let falsePositives = ok.filter { !LocalRules.check($0, level: level).isEmpty }
            XCTAssertEqual(falsePositives, [], name)
            print("LOCAL EVALUATION \(name): caught=\(hits.count)/\(bad.count), falsePositives=\(falsePositives.count)/\(ok.count)")
            print("LOCAL MISSES \(name): \(bad.filter { !hits.contains($0) })")
        }
    }
    func testLongUnpunctuatedTextOnlyOffersAdvice() {
        let text = String(repeating: "文", count: 26)
        let edits = LocalRules.check(text, level: .strict)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.kind, .fluency)
        XCTAssertEqual(edits.first?.canApply, false)
        XCTAssertNil(SuggestionPreview(source: text, edits: edits))
        XCTAssertNil(SuggestionPreview.wholeRewrite(source: text, edits: edits))
        let mixed = "😀" + String(repeating: "文", count: 13) + "API123" + String(repeating: "文", count: 13)
        let hint = LocalRules.check(mixed, level: .strict).first!
        XCTAssertEqual(hint.range.location, 2)
        XCTAssertTrue(hint.matches(mixed))
        let typo = Suggestion(range: NSRange(location: 0, length: 1), original: "文", replacement: "字", kind: .typo, why: "")
        XCTAssertEqual(SuggestionPreview(source: text, edits: edits + [typo])?.output, "字" + String(text.dropFirst()))
        XCTAssertEqual(edits.first?.why, "这句较长，可以断开")
        XCTAssertTrue(LocalRules.check(String(repeating: "文", count: 25), level: .strict).isEmpty)
        for level in [Strictness.standard, .relaxed] { XCTAssertTrue(LocalRules.check(text, level: level).isEmpty) }
        for delimiter in ["，", ",", "。", "：", ";", "\n"] {
            XCTAssertTrue(LocalRules.check(String(repeating: "文", count: 13) + delimiter + String(repeating: "文", count: 13), level: .strict).filter { $0.kind == .fluency }.isEmpty)
        }
        XCTAssertTrue(LocalRules.check("「" + text + "」", level: .strict).isEmpty)
        XCTAssertTrue(LocalRules.check("“就是我觉得这样其实还可以吧”", level: .strict).isEmpty)
    }
}
