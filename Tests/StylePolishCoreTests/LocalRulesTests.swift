import XCTest
@testable import StylePolishCore

final class LocalRulesTests: XCTestCase {
    func testSampleAndUTF16() {
        let text = "😀我因该明天在在给你回复，，文件以经发了"
        let edits = LocalRules.check(text, level: .standard)
        XCTAssertEqual(edits.count, 4)
        XCTAssertTrue(edits.allSatisfy { $0.matches(text) })
        XCTAssertEqual(edits.first?.range.location, 3)
    }
    func testNaturalRepetitions() {
        for text in ["看看", "试试", "谢谢", "哈哈哈", "刚刚", "常常", "天天", "慢慢来", "好的的确如此", "一个个", "是是非非", "等等", "卿卿我我", "和和气气", "和和美美", "你你我我", "在次日", "再接再厉", "中文 English API"] {
            XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
        }
    }
}

extension LocalRulesTests {
    func testEveryTypoAndLiteralCounterexample() {
        XCTAssertGreaterThanOrEqual(LocalRules.typos.count, 120)
        for (wrong, right) in LocalRules.typos {
            // 因该 is restricted to a personal-pronoun context.
            let edits = LocalRules.check(wrong == "因该" ? "我因该回复" : wrong, level: .relaxed)
            XCTAssertEqual(edits.count, 1, wrong)
            XCTAssertEqual(edits.first?.replacement, right, wrong)
            XCTAssertTrue(LocalRules.check(right, level: .strict).isEmpty, right)
            // Discussing the spelling itself is a valid use of the wrong literal.
            XCTAssertTrue(LocalRules.check("词表收录了「\(wrong)」这个错写字面。", level: .strict).isEmpty, wrong)
        }
    }
    func testWhitelistsAndLevels() {
        for char in "的了是在我你他她和就也都把被给" {
            let input = String(repeating: String(char), count: 3)
            XCTAssertEqual(LocalRules.check(input, level: .relaxed).first?.replacement, String(char))
        }
        for word in ["然后", "就是", "那个", "这个", "因为", "所以", "但是", "可以", "我们", "已经"] {
            XCTAssertTrue(LocalRules.check(word + word, level: .relaxed).isEmpty)
            XCTAssertEqual(LocalRules.check(word + word + word, level: .standard).first?.replacement, word)
        }
        for value in ["，，", "；；", "：：", "、、", "。。"] {
            XCTAssertEqual(LocalRules.check(value, level: .relaxed).first?.replacement, String(value.prefix(1)))
        }
        for value in ["？？", "！！！", "。。。", "。。。。", "的了是在"] { XCTAssertTrue(LocalRules.check(value, level: .strict).isEmpty) }
        XCTAssertTrue(LocalRules.check("中文,测试", level: .standard).isEmpty)
        XCTAssertEqual(LocalRules.check("中文,测试", level: .strict).first?.replacement, "，")
        XCTAssertTrue(LocalRules.check("a,中文 中文,2", level: .strict).isEmpty)
    }
    func testAliasesAndOverlap() {
        let input = "😀因该因该在在"
        let edits = LocalRules.check(input, level: .standard, aliases: ["因该因该": "应该", "因该": "应该", "": "无效"])
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits.first?.original, "因该因该")
        for (left, right) in zip(edits, edits.dropFirst()) { XCTAssertLessThanOrEqual(NSMaxRange(left.range), right.range.location) }
        XCTAssertTrue(edits.allSatisfy { $0.matches(input) })
    }
    func test500CharactersUnderFiveMilliseconds() {
        let seeds = [
            "这是一段普通文字，用来测试本地检查的速度。",
            "😀我己经发了，文件以经发了。请列出步聚，数据同步聚合。我自己经常发详细截图。",
            LocalRules.typos.keys.sorted().joined(separator: "，") + "。"
        ]
        for (index, seed) in seeds.enumerated() {
            let input = String(String(repeating: seed, count: 30).prefix(500))
            XCTAssertEqual(input.count, 500)
            _ = LocalRules.check(input, level: .strict) // resource/regex cold start excluded
            var samples: [Double] = []
            for _ in 0..<100 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = LocalRules.check(input, level: .strict)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let mean = samples.reduce(0, +) / Double(samples.count), maxMS = samples.max()!
            print("LocalRules 500 characters corpus \(index) mean: \(mean) ms, max: \(maxMS) ms")
            XCTAssertLessThan(maxMS, 5, "Corpus \(index)")
        }
    }
}

extension LocalRulesTests {
    func testEveryDailyTypoHasPositiveAndNaturalCounterexample() throws {
        struct Case: Decodable { let wrong: String; let right: String; let counterexample: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/daily-typo-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(cases.map(\.wrong)).count, cases.count, "Daily fixture must not contain duplicate entries")
        XCTAssertFalse(cases.isEmpty)
        for entry in cases {
            XCTAssertEqual(LocalRules.typos[entry.wrong], entry.right)
            let edits = LocalRules.check("请检查：\(entry.wrong)。", level: .relaxed)
            XCTAssertEqual(edits.count, 1, entry.wrong)
            XCTAssertEqual(edits.first?.replacement, entry.right, entry.wrong)
            XCTAssertTrue(LocalRules.check(entry.counterexample, level: .strict).isEmpty, entry.counterexample)
            XCTAssertTrue(LocalRules.check("文中引用「\(entry.wrong)」作为错字示例。", level: .strict).isEmpty, entry.wrong)
        }
        for normal in ["帐号可正常使用", "登陆火星", "登陆舰", "台风登陆", "在见面前准备", "在次日回复", "再见", "即便如此", "既然如此", "那怕什么", "按排名排序", "按排号入场", "这是合并请求", "本地部署", "阀门开度", "需要做作业", "正常的地名", "泄漏检测", "身份证明"] {
            XCTAssertTrue(LocalRules.check(normal, level: .strict).isEmpty, normal)
        }
    }
}

extension LocalRulesTests {
    func testReviewCrossWordSentences() {
        for text in ["我自己经常这样", "自己经历过", "自己经过", "发个详细截图", "数据同步聚合", "官网各个页面",
                     "优先及时处理", "顺延申请", "确认征求意见", "没有郊游", "学生郊游", "事情序号", "教材科目", "资格试用"] {
            XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
        }
    }

    func testTwoCharacterTyposHaveNaturalPositivesAndTwoCrossWordCounterexamples() throws {
        struct Case: Decodable {
            let wrong: String; let right: String; let positive: String; let counterexamples: [String]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/two-character-typo-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(cases.map(\.wrong)), Set(LocalRules.typos.keys.filter { $0.count == 2 }))
        for entry in cases {
            XCTAssertEqual(LocalRules.typos[entry.wrong], entry.right, entry.wrong)
            let edits = LocalRules.check(entry.positive, level: .relaxed)
            XCTAssertEqual(edits.count, 1, entry.positive)
            XCTAssertEqual(edits.first?.replacement, entry.right, entry.positive)
            XCTAssertTrue(edits.allSatisfy { $0.matches(entry.positive) }, entry.positive)
            XCTAssertGreaterThanOrEqual(Set(entry.counterexamples).count, 2, entry.wrong)
            for text in entry.counterexamples {
                XCTAssertTrue(text.contains(entry.wrong), "Counterexample must exercise the literal: \(entry.wrong)")
                XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
            }
        }
    }

    func testWordBoundariesProtectOriginalAndLongerEntriesWithUTF16Offsets() {
        // Includes an original entry, a three-character entry and a four-character entry.
        for text in ["😀所以经常这样", "他分辩率先离场是因为身体不适", "优先及时处理", "联系方试图再次沟通"] {
            XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
        }
        let text = "😀我己经发了，文件以经发了"
        let edits = LocalRules.check(text, level: .relaxed)
        XCTAssertEqual(edits.map(\.original), ["己经", "以经"])
        XCTAssertEqual(edits.first?.range.location, 3)
        XCTAssertTrue(edits.allSatisfy { $0.matches(text) })
    }
}

extension LocalRulesTests {
    func testReviewPositiveSentencesRemainCovered() {
        let cases = [
            ("我己经发了", "己经", "已经"), ("请补充细截", "细截", "细节"),
            ("请列出步聚", "步聚", "步骤"), ("网各连接失败", "网各", "网络"),
            ("优先及很高", "优先及", "优先级"), ("话题继续延申", "延申", "延伸"),
            ("身份认征通过", "认征", "认证"), ("这个方法有郊", "有郊", "有效"),
            // The broad 生郊 entry is retired; keep the established collocation.
            ("盖章生郊", "盖章生郊", "盖章生效"), ("需要控制情序", "情序", "情绪"),
            ("请提交材科", "材科", "材料"), ("文件格试错误", "格试", "格式")
        ]
        for (text, wrong, right) in cases {
            let edits = LocalRules.check(text, level: .standard)
            XCTAssertEqual(edits.count, 1, text)
            XCTAssertEqual(edits.first?.original, wrong, text)
            XCTAssertEqual(edits.first?.replacement, right, text)
        }
    }

    func testRetiredEntriesStayRemovedAndNaturalSentencesStayUnchanged() throws {
        struct Case: Decodable { let wrong: String; let reason: String; let counterexamples: [String] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retired-typo-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        for entry in cases {
            XCTAssertNil(LocalRules.typos[entry.wrong], entry.wrong)
            XCTAssertFalse(entry.reason.isEmpty, entry.wrong)
            XCTAssertTrue(LocalRules.check(entry.wrong, level: .strict).isEmpty, entry.wrong)
            for text in entry.counterexamples {
                XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
            }
        }
        XCTAssertEqual(cases.count + LocalRules.typos.keys.filter { $0.count == 2 }.count, 119,
                       "Audit must account for every original two-character entry")
    }
}

extension LocalRulesTests {
    func testSingleCharacterWordsCanStillFormValidPhrases() {
        for text in ["因该设备故障停机", "因该项目延期而调整预算", "这杯水要加蜜才好喝", "请在茶里加蜜",
                     "这个阀值五百元", "这个阀值多少钱", "还需耍几套拳", "这场戏需耍两次刀"] {
            XCTAssertTrue(LocalRules.check(text, level: .strict).isEmpty, text)
        }
        for text in ["我因该回复", "你因该回家", "我们因该出发", "他们因该知道"] {
            XCTAssertEqual(LocalRules.check(text, level: .relaxed).first?.replacement, "应该", text)
        }
    }
}
