import Foundation
import Testing

@testable import TaskboardKit

@Suite("音声入力の送信の合図")
struct DictationCueTests {
    @Test("区切りの最後の「送信」で送り、合図を除いた文を返す", arguments: [
        ("PR をマージしてください。送信", "PR をマージしてください。"),
        ("PR をマージしてください送信", "PR をマージしてください"),
        ("テストを回して、送信。", "テストを回して"),
        ("確認をお願いします 送信して", "確認をお願いします"),
        ("Deploy して. 送信!", "Deploy して."),
    ])
    func trailingCue(text: String, body: String) {
        #expect(DictationCue.split(text) == .init(body: body, send: true))
    }

    @Test("合図だけを話したら、本文は空で送る")
    func cueOnly() {
        #expect(DictationCue.split("送信。") == .init(body: "", send: true))
        #expect(DictationCue.split(" 送信して ") == .init(body: "", send: true))
    }

    @Test("文の途中の「送信」と、助詞に続く「送信」は合図にしない", arguments: [
        "メールを送信する処理を直して",
        "メールを送信",
        "Slack に送信",
        "結果の送信",
        "送信ボタンを押した後に止まる",
        "送信して終わりにする処理",
    ])
    func notCue(text: String) {
        #expect(DictationCue.split(text) == .init(body: text, send: false))
    }

    @Test("「送って」は合図にしない")
    func okutteIsContent() {
        #expect(DictationCue.split("PR のリンクを送って") == .init(body: "PR のリンクを送って", send: false))
    }

    @Test("助詞の後でも、句読点か空白で区切れば合図にする")
    func separatedAfterParticle() {
        #expect(DictationCue.split("メールを。送信") == .init(body: "メールを。", send: true))
        #expect(DictationCue.split("メールを 送信") == .init(body: "メールを", send: true))
    }

    @Test("空の文と合図の無い文はそのまま")
    func empty() {
        #expect(DictationCue.split("") == .init(body: "", send: false))
        #expect(DictationCue.split("こんにちは。") == .init(body: "こんにちは。", send: false))
    }

    @Test("合図は校正の前の文で決めるので、校正が合図を消しても言い換えても、本文の校正の結果だけを送る")
    func decidedBeforePolish() {
        let split = DictationCue.split("ストップ放棄を見直して。送信")
        #expect(split.send)
        // 校正には本文だけを渡す。校正した文が偶然「送信」で終わっても、もう一度は見ない（本文に合図は入っていない）
        #expect(split.body == "ストップ放棄を見直して。")
        #expect(DictationCue.split("Stop hook を見直して送信").body == "Stop hook を見直して")
    }
}

@Suite("音声入力の区切りの置き換え")
struct DictationSpanTests {
    @Test("入れた位置のままなら、そこを置き換える")
    func inPlace() {
        let span = DictationSpan(start: 3, text: "すとっぷ")
        let result = span.replacing(with: "Stop hook", in: "前の文すとっぷ後ろ")
        #expect(result?.text == "前の文Stop hook後ろ")
        #expect(result?.span == DictationSpan(start: 3, text: "Stop hook"))
    }

    @Test("前に打ち足して位置がずれても、同じ文を探して置き換える")
    func shifted() {
        let span = DictationSpan(start: 0, text: "あいう")
        let result = span.replacing(with: "ABC", in: "打ち足したあいう")
        #expect(result?.text == "打ち足したABC")
        #expect(result?.span.start == 5)
    }

    @Test("同じ文が 2 つあれば、入れた位置に近い方を置き換える")
    func nearest() {
        let span = DictationSpan(start: 6, text: "はい")
        #expect(span.replacing(with: "了解", in: "はい、そう。はい")?.text == "はい、そう。了解")
    }

    @Test("区切りの文を打ち直していれば置き換えない")
    func edited() {
        #expect(DictationSpan(start: 0, text: "元の文").replacing(with: "校正", in: "元のぶん") == nil)
        #expect(DictationSpan(start: 0, text: "").replacing(with: "校正", in: "何か") == nil)
        #expect(DictationSpan(start: 0, text: "長い区切り").replacing(with: "校正", in: "短") == nil)
    }

    @Test("英数字と日本語が混ざっても字数で位置を数える")
    func mixed() {
        let span = DictationSpan(start: 4, text: "🎉です")
        #expect(span.replacing(with: "でした", in: "abcd🎉です。")?.text == "abcdでした。")
    }
}

@Suite("音声入力で会話の問いに答える")
struct DictationAnswerTests {
    private let question = AskQuestion(
        id: "q1", question: "どちらにしますか", options: [AskOption(label: "OAuth (Recommended)"), AskOption(label: "API キー"), AskOption(label: "やめる")])

    @Test("選択肢の名前と一致すれば、その選択肢を選ぶ（送るのは推奨の印の付いた label）", arguments: [
        ("OAuth", "OAuth (Recommended)"), ("oauth。", "OAuth (Recommended)"), ("ＡＰＩキー", "API キー"), ("API キーでお願いします", "API キー"), ("やめるにします", "やめる"),
    ])
    func label(text: String, label: String) {
        #expect(DictationAnswer.match(text, questions: [question]) == .selected(AskAnswer(questionID: "q1", selected: [label])))
    }

    @Test("番号で選ぶ", arguments: [("1番", 0), ("２番目", 1), ("3つ目で", 2), ("一番", 0), ("最初", 0), ("最後で", 2), ("選択肢2", 1), ("2", 1)])
    func number(text: String, index: Int) {
        #expect(DictationAnswer.match(text, questions: [question]) == .selected(AskAnswer(questionID: "q1", selected: [question.options[index].label])))
    }

    @Test("一致しない文と、選択肢の数を超えた番号は自由記述にする")
    func freeText() {
        #expect(
            DictationAnswer.match("OAuth にしたいが、期限は短く", questions: [question])
                == .freeText(AskAnswer(questionID: "q1", selected: [], freeText: "OAuth にしたいが、期限は短く")))
        #expect(DictationAnswer.match("4番", questions: [question]) == .freeText(AskAnswer(questionID: "q1", selected: [], freeText: "4番")))
        #expect(DictationAnswer.match("一番いいのは", questions: [question]) == .freeText(AskAnswer(questionID: "q1", selected: [], freeText: "一番いいのは")))
    }

    @Test("2 問なら、どちらか 1 問の選択肢の名前とだけ一致したときに、その問いに答える")
    func twoQuestions() {
        let second = AskQuestion(id: "q2", question: "いつ出しますか", options: [AskOption(label: "今日"), AskOption(label: "明日")])
        #expect(DictationAnswer.match("明日で", questions: [question, second]) == .selected(AskAnswer(questionID: "q2", selected: ["明日"])))
        #expect(DictationAnswer.match("1番", questions: [question, second]) == .undetermined)
        #expect(DictationAnswer.match("OAuth で明日", questions: [question, second]) == .undetermined)
    }

    @Test("2 問の両方に同じ名前の選択肢があれば決めない")
    func sameLabelTwice() {
        let a = AskQuestion(id: "a", question: "A", options: [AskOption(label: "はい"), AskOption(label: "いいえ")])
        let b = AskQuestion(id: "b", question: "B", options: [AskOption(label: "はい"), AskOption(label: "いいえ")])
        #expect(DictationAnswer.match("はい", questions: [a, b]) == .undetermined)
    }

    @Test("伏せて入力する問いと、空の文と、問いが無いときは答えない")
    func refuses() {
        let secret = AskQuestion(id: "s", question: "token", options: [AskOption(label: "x")], isSecret: true)
        #expect(DictationAnswer.match("x", questions: [secret]) == .undetermined)
        #expect(DictationAnswer.match("。", questions: [question]) == .undetermined)
        #expect(DictationAnswer.match("OAuth", questions: []) == .undetermined)
    }
}
