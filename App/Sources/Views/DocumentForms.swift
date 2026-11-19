import Foundation
import TaskboardKit

/// 文書の本文の中に描く、質問と送る文面の欄（WKWebView の中の HTML）。本文の印 `<!-- ask: q1 -->`・`<!-- draft: id -->` の位置に置き、
/// 印の無いものは本文の末尾にまとめる。答えと承認は `MessageProxy` でアプリに返し、daemon の回答・承認の API は今のものを使う
@MainActor
enum DocumentForms {
    /// 本文の印を欄の置き場に替え、末尾の置き場を足す。印の規則は daemon の照合と同じ `DocMarkers`
    static func placeSlots(in html: String) -> String {
        DocMarkers.replace(in: html) { "<div class=\"tb-slot\" data-tb-slot=\"\($0.slot)\"></div>" }
    }

    static let endSlot = "<div id=\"tb-forms-end\" class=\"tb-forms-end\"></div><div id=\"tb-forms-bar\" class=\"tb-forms-bar\" hidden></div>"

    /// 欄に出す質問の束: 本文と一緒に出した最新の束（印の位置）と、その後に `ask_user` で付けた束（末尾）
    static func shownAsks(_ asks: [Ask]) -> [Ask] {
        let sorted = asks.sorted { $0.askID < $1.askID }
        let body = sorted.last { $0.inBody }
        let attached = sorted.last { !$0.inBody && $0.askID > (body?.askID ?? 0) && $0.status != .cancelled }
        return [body, attached].compactMap { $0 }
    }

    // MARK: 欄に渡す中身

    struct Payload: Encodable {
        var canWrite: Bool
        var blocked: String?
        var labels: [String: String]
        var asks: [AskItem]
        var drafts: [DraftItem]
    }

    struct AskItem: Encodable {
        var askID: Int64
        var status: String
        var inBody: Bool
        var delivered: Bool
        var questions: [QuestionItem]
        var answers: [AnswerItem]
    }

    struct QuestionItem: Encodable {
        var id: String
        var question: String
        var header: String?
        var multiSelect: Bool
        var isSecret: Bool
        var options: [OptionItem]
    }

    struct OptionItem: Encodable {
        var label: String
        var display: String
        var description: String?
        var recommended: Bool
        /// 見本の頁（sandbox の iframe の srcdoc）
        var preview: String?
    }

    struct AnswerItem: Encodable {
        var questionID: String
        var selected: [String]
        var freeText: String?
    }

    struct DraftItem: Encodable {
        var id: String
        var title: String
        var to: String
        var body: String
        var checks: [CheckItem]
        /// 承認の表示（「承認済み（10:42）」）。承認を待つ間は nil
        var approved: String?
        var approvedBody: String?
    }

    struct CheckItem: Encodable {
        var label: String
        var ok: Bool
        var note: String
    }

    static func payload(asks: [Ask], drafts: [DocDraft], canWrite: Bool, blocked: String?, textSize: Double) -> Payload {
        Payload(
            canWrite: canWrite, blocked: blocked, labels: labels,
            asks: shownAsks(asks).map { askItem($0, textSize: textSize) },
            drafts: drafts.map(draftItem))
    }

    private static func askItem(_ ask: Ask, textSize: Double) -> AskItem {
        AskItem(
            askID: ask.askID, status: ask.status.rawValue, inBody: ask.inBody, delivered: ask.deliveredAt != nil,
            questions: ask.questions.map { q in
                QuestionItem(
                    id: q.id, question: q.question, header: q.header, multiSelect: q.multiSelect, isSecret: q.isSecret,
                    options: q.options.map { option in
                        OptionItem(
                            label: option.label, display: option.displayLabel, description: option.description, recommended: option.isRecommended,
                            preview: option.preview.map { previewPage($0, html: option.previewIsHTML, textSize: textSize) })
                    })
            },
            answers: (ask.answers ?? []).map { AnswerItem(questionID: $0.questionID, selected: $0.selected, freeText: $0.freeText) })
    }

    private static func draftItem(_ draft: DocDraft) -> DraftItem {
        let approved = draft.answer.map { answer in
            let time = answer.answeredAt.formatted(date: .omitted, time: .shortened)
            return answer.edited ? String(localized: "編集した本文で承認済み（\(time)）") : String(localized: "承認済み（\(time)）")
        }
        return DraftItem(
            id: draft.id, title: draft.draft.title, to: String(localized: "宛先：\(draft.draft.to)"), body: draft.draft.body,
            checks: draft.draft.checks.map { CheckItem(label: $0.label, ok: $0.ok, note: $0.note) }, approved: approved, approvedBody: draft.answer?.body)
    }

    /// 見本は本文と同じ組み立ての頁にし、script を止めた iframe に載せる
    private static func previewPage(_ preview: String, html: Bool, textSize: Double) -> String {
        DocumentWebController.html(for: DocContent(docID: 0, rev: 0, format: html ? .html : .markdown, content: preview), textSize: textSize, forms: false)
    }

    /// 欄の文字。JS に直書きせず、画面の catalog に載せる
    private static var labels: [String: String] {
        [
            "questions": String(localized: "質問"),
            "recommended": String(localized: "推奨"),
            "freeText": String(localized: "自由記述"),
            "preview": String(localized: "見本："),
            "send": String(localized: "回答を送信"),
            "sending": String(localized: "送信しています…"),
            "sendHelp": String(localized: "回答を送信（⌘↩）"),
            "close": String(localized: "質問を閉じる"),
            "closeHelp": String(localized: "答えずに閉じる（チャットで話して済んだとき）"),
            "next": String(localized: "次の未回答へ"),
            "allRequired": String(localized: "すべての質問に答えると送信できます。"),
            "answered": String(localized: "回答済み"),
            "cancelled": String(localized: "取り下げ済み"),
            "undelivered": String(localized: "セッションへの送信待ち"),
            "draft": String(localized: "送る文面"),
            "body": String(localized: "本文"),
            "approve": String(localized: "承認"),
            "approveHelp": String(localized: "承認（⌘↩）"),
            "restore": String(localized: "元の本文に戻す"),
            "checkOK": String(localized: "問題なし"),
            "checkNG": String(localized: "要確認"),
        ]
    }

    // MARK: 見た目と動き

    /// 色はシステムの色（`attentionCard` と同じ橙）、余白と角丸は `Space`・`Radius` の値
    static var style: String {
        """
        .tb-slot:empty{display:none}
        .tb-markdown .tb-forms-end{max-width:760px;margin:0 auto}
        .tb-form{font:14px/1.6 -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;color:CanvasText;margin:\(Int(Space.block))px 0;padding:\(Int(Space.card))px;border-radius:\(Int(Radius.card))px;background:rgba(127,127,127,.08);text-align:left}
        .tb-markdown .tb-form{font-size:var(--tb-size,14px)}
        .tb-form.tb-open{background:rgba(255,149,0,.07);border:1px solid rgba(255,149,0,.35)}
        .tb-form.tb-flash{box-shadow:0 0 0 3px rgba(255,149,0,.45)}
        .tb-form-head{display:flex;gap:\(Int(Space.inline))px;align-items:center;flex-wrap:wrap;font-size:.86em;color:GrayText;margin-bottom:\(Int(Space.inline))px}
        .tb-form-kind{color:#c56a00;font-weight:600}
        @media (prefers-color-scheme: dark){.tb-form-kind{color:#ff9f0a}}
        .tb-chip{font-size:.86em;padding:1px 7px;border-radius:999px;background:rgba(127,127,127,.15);color:GrayText}
        .tb-chip.tb-accent{background:color-mix(in srgb,AccentColor 15%,transparent);color:AccentColor}
        .tb-question{font-weight:600;margin:0 0 \(Int(Space.row))px;white-space:pre-wrap}
        .tb-options-row{display:flex;gap:\(Int(Space.block))px;align-items:flex-start}
        .tb-options-row>*{flex:1 1 0;min-width:0}
        @media (max-width:640px){.tb-options-row{display:block}}
        .tb-options{display:flex;flex-direction:column;gap:2px}
        .tb-option{all:unset;box-sizing:border-box;display:flex;gap:\(Int(Space.row))px;align-items:baseline;min-height:28px;padding:3px \(Int(Space.inline))px;border-radius:\(Int(Radius.control))px;cursor:pointer}
        .tb-option:hover{background:rgba(127,127,127,.1)} .tb-option:focus-visible{outline:2px solid AccentColor}
        .tb-option[aria-disabled=true]{cursor:default} .tb-option[aria-disabled=true]:hover{background:none}
        .tb-mark{flex:none;width:1em;text-align:center;color:GrayText} .tb-option[aria-checked=true] .tb-mark{color:AccentColor}
        .tb-option-desc{display:block;font-size:.86em;color:GrayText}
        .tb-preview-label{font-size:.86em;color:GrayText;margin-bottom:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .tb-preview iframe{width:100%;height:\(Int(AskFormMetrics.previewHeight))px;border:1px solid rgba(127,127,127,.25);border-radius:\(Int(Radius.box))px;background:Canvas}
        .tb-form textarea,.tb-form input[type=password]{box-sizing:border-box;width:100%;margin-top:\(Int(Space.row))px;font:inherit;color:inherit;background:Canvas;border:1px solid rgba(127,127,127,.4);border-radius:\(Int(Radius.control))px;padding:\(Int(Space.inline))px \(Int(Space.row))px;resize:vertical}
        .tb-form textarea:disabled{opacity:.6}
        .tb-answer{margin-top:\(Int(Space.inline))px;white-space:pre-wrap}
        .tb-status{font-size:.86em;color:GrayText;margin-top:\(Int(Space.inline))px}
        .tb-checks{display:flex;flex-wrap:wrap;gap:\(Int(Space.inline))px \(Int(Space.block))px;font-size:.86em;color:GrayText;margin-top:\(Int(Space.row))px}
        .tb-check-ng{color:#c56a00} @media (prefers-color-scheme: dark){.tb-check-ng{color:#ff9f0a}}
        .tb-actions{display:flex;gap:\(Int(Space.row))px;align-items:center;justify-content:flex-end;flex-wrap:wrap;margin-top:\(Int(Space.row))px}
        .tb-actions .tb-hint{margin-right:auto;font-size:.86em;color:GrayText}
        .tb-button{font:13px -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;padding:4px 12px;border-radius:\(Int(Radius.control))px;border:1px solid rgba(127,127,127,.4);background:Canvas;color:CanvasText;cursor:pointer}
        .tb-button.tb-primary{background:AccentColor;border-color:AccentColor;color:#fff}
        .tb-button:disabled{opacity:.45;cursor:default}
        .tb-error{color:#d70015;font-size:.86em;margin-top:\(Int(Space.inline))px} @media (prefers-color-scheme: dark){.tb-error{color:#ff6961}}
        .tb-forms-bar{position:fixed;left:0;right:0;bottom:0;padding:\(Int(Space.row))px \(Int(Space.block))px;background:color-mix(in srgb,Canvas 92%,transparent);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border-top:1px solid rgba(255,149,0,.35);font:13px -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;color:CanvasText}
        .tb-forms-bar .tb-actions{margin:0;max-width:760px;margin:0 auto}
        body.tb-has-bar{padding-bottom:96px}
        """
    }

    /// 欄の描画と答えの受け渡し。`__tbForms.set(payload)` で描き直す（書きかけの選択と文は残す）
    static let script = """
        (function(){
        const F = window.__tbForms = { data: null, picks: {}, texts: {}, focus: {}, drafts: {}, busy: {}, errors: {}, pendingScroll: null };
        function post(m){ if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tb) window.webkit.messageHandlers.tb.postMessage(m); }
        function el(tag, cls, text){ const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
        function L(k){ return (F.data && F.data.labels[k]) || k; }
        function slot(name){ return document.querySelector('[data-tb-slot="' + CSS.escape(name) + '"]'); }
        function key(askID, q){ return askID + '/' + q; }
        function cardName(ask, q){ return 'ask:' + (ask.inBody ? q.id : ask.askID + '.' + q.id); }
        function picks(askID, q){ const k = key(askID, q); return F.picks[k] || (F.picks[k] = []); }
        function openAsk(){ return F.data && F.data.asks.find(a => a.status === 'open'); }
        function writable(){ return F.data && F.data.canWrite && !F.data.blocked; }
        function answerFor(ask, q){
          const text = (F.texts[key(ask.askID, q.id)] || '').trim();
          const selected = q.options.map(o => o.label).filter(l => picks(ask.askID, q.id).includes(l));
          return { questionID: q.id, selected: selected, freeText: text ? text : null };
        }
        function unanswered(ask){ return ask.questions.filter(q => { const a = answerFor(ask, q); return a.selected.length === 0 && !a.freeText; }); }
        function pending(){
          let has = false;
          const ask = openAsk();
          if (ask) has = ask.questions.some(q => picks(ask.askID, q.id).length > 0 || (F.texts[key(ask.askID, q.id)] || '').trim());
          for (const d of (F.data ? F.data.drafts : [])) { const s = F.drafts[d.id]; if (!d.approved && s && s.text !== d.body) has = true; }
          post({ type: 'formsPending', value: has });
        }
        function previewOption(ask, q){
          const withPreview = q.options.filter(o => o.preview);
          if (!withPreview.length) return null;
          const f = F.focus[key(ask.askID, q.id)];
          return withPreview.find(o => o.label === f) || withPreview.find(o => picks(ask.askID, q.id).includes(o.label)) || withPreview.find(o => o.recommended) || withPreview[0];
        }
        function questionCard(ask, q){
          const open = ask.status === 'open', live = open && writable();
          const card = el('section', 'tb-form' + (open ? ' tb-open' : ''));
          card.dataset.tbCard = cardName(ask, q);
          const head = el('div', 'tb-form-head');
          head.append(el('span', 'tb-form-kind', L('questions')));
          if (q.header) head.append(el('span', 'tb-chip', q.header));
          if (!open) head.append(el('span', 'tb-chip', ask.status === 'answered' ? L('answered') : L('cancelled')));
          card.append(head);
          const title = el('p', 'tb-question', q.question); title.id = 'tb-q-' + ask.askID + '-' + q.id; card.append(title);
          const given = ask.answers.find(a => a.questionID === q.id);
          const chosen = open ? picks(ask.askID, q.id) : (given ? given.selected : []);
          const list = el('div', 'tb-options');
          list.setAttribute('role', q.multiSelect ? 'group' : 'radiogroup'); list.setAttribute('aria-labelledby', title.id);
          for (const o of q.options) {
            const on = chosen.includes(o.label);
            const b = el('button', 'tb-option'); b.type = 'button';
            b.setAttribute('role', q.multiSelect ? 'checkbox' : 'radio'); b.setAttribute('aria-checked', on ? 'true' : 'false');
            if (!live) b.setAttribute('aria-disabled', 'true');
            b.append(el('span', 'tb-mark', q.multiSelect ? (on ? '☑' : '☐') : (on ? '◉' : '○')));
            const text = el('span'); text.append(el('span', null, o.display));
            if (o.recommended) { text.append(' '); text.append(el('span', 'tb-chip tb-accent', L('recommended'))); }
            if (o.description) text.append(el('span', 'tb-option-desc', o.description));
            b.append(text);
            if (live) {
              b.addEventListener('click', () => {
                const k = key(ask.askID, q.id); let s = picks(ask.askID, q.id);
                if (q.multiSelect) { s = s.includes(o.label) ? s.filter(x => x !== o.label) : s.concat([o.label]); } else { s = s.includes(o.label) ? [] : [o.label]; }
                F.picks[k] = s; F.focus[k] = o.label; render(); pending(); const again = document.querySelector('[data-tb-card="' + CSS.escape(cardName(ask, q)) + '"] .tb-option:nth-child(' + (q.options.indexOf(o) + 1) + ')'); if (again) again.focus();
              });
            }
            if (o.preview) b.addEventListener('mouseenter', () => { const k = key(ask.askID, q.id); if (F.focus[k] !== o.label) { F.focus[k] = o.label; updatePreview(card, ask, q); } });
            list.append(b);
          }
          const preview = previewOption(ask, q);
          if (preview) {
            const row = el('div', 'tb-options-row'); row.append(list);
            const box = el('div', 'tb-preview'); row.append(box); card.append(row); fillPreview(box, preview);
          } else {
            card.append(list);
          }
          if (live) {
            const k = key(ask.askID, q.id);
            const input = q.isSecret ? el('input') : el('textarea');
            if (q.isSecret) input.type = 'password'; else input.rows = 2;
            input.placeholder = L('freeText'); input.setAttribute('aria-label', L('freeText')); input.value = F.texts[k] || '';
            input.addEventListener('input', () => { F.texts[k] = input.value; updateBar(); pending(); });
            card.append(input);
          } else if (given && given.freeText) {
            card.append(el('div', 'tb-answer', given.freeText));
          }
          if (ask.status === 'answered' && !ask.delivered) card.append(el('div', 'tb-status', L('undelivered')));
          return card;
        }
        function fillPreview(box, option){
          box.replaceChildren(el('div', 'tb-preview-label', L('preview') + option.display));
          const frame = document.createElement('iframe'); frame.setAttribute('sandbox', ''); frame.setAttribute('title', L('preview') + option.display); frame.srcdoc = option.preview; box.append(frame);
        }
        function updatePreview(card, ask, q){ const box = card.querySelector('.tb-preview'); const o = previewOption(ask, q); if (box && o) fillPreview(box, o); }
        function draftCard(d){
          const live = !d.approved && writable();
          const card = el('section', 'tb-form' + (d.approved ? '' : ' tb-open'));
          card.dataset.tbCard = 'draft:' + d.id;
          const head = el('div', 'tb-form-head');
          head.append(el('span', 'tb-form-kind', L('draft')));
          if (d.title) head.append(el('span', null, d.title));
          card.append(head);
          card.append(el('div', 'tb-status', d.to));
          if (d.approved) {
            card.append(el('div', 'tb-answer', d.approvedBody || d.body));
            card.append(el('div', 'tb-status', '✓ ' + d.approved));
            return card;
          }
          const state = F.drafts[d.id] && F.drafts[d.id].original === d.body ? F.drafts[d.id] : (F.drafts[d.id] = { original: d.body, text: d.body });
          const area = el('textarea'); area.rows = Math.min(16, Math.max(4, d.body.split('\\n').length + 1)); area.value = state.text; area.setAttribute('aria-label', L('body')); area.disabled = !live;
          card.append(area);
          if (d.checks.length) {
            const checks = el('div', 'tb-checks');
            for (const c of d.checks) {
              const item = el('span', c.ok ? null : 'tb-check-ng', (c.ok ? '✓ ' : '⚠︎ ') + (c.note ? c.label + '：' + c.note : c.label));
              item.setAttribute('aria-label', c.label + '、' + (c.ok ? L('checkOK') : L('checkNG')));
              checks.append(item);
            }
            card.append(checks);
          }
          if (F.errors['draft:' + d.id]) card.append(el('div', 'tb-error', F.errors['draft:' + d.id]));
          const actions = el('div', 'tb-actions');
          const restore = el('button', 'tb-button', L('restore')); restore.type = 'button'; restore.hidden = state.text === d.body;
          restore.addEventListener('click', () => { state.text = d.body; area.value = d.body; restore.hidden = true; approve.disabled = !live; pending(); });
          const approve = el('button', 'tb-button tb-primary', L('approve')); approve.type = 'button'; approve.title = L('approveHelp');
          approve.disabled = !live || !state.text.trim() || !!F.busy['draft:' + d.id];
          approve.addEventListener('click', () => approveDraft(d));
          area.addEventListener('input', () => { state.text = area.value; restore.hidden = state.text === d.body; approve.disabled = !live || !state.text.trim(); pending(); });
          actions.append(restore, approve); card.append(actions);
          return card;
        }
        function approveDraft(d){
          const state = F.drafts[d.id]; if (!state || !state.text.trim() || !writable()) return;
          post({ type: 'approveDraft', draftID: d.id, body: state.text });
        }
        function send(){
          const ask = openAsk(); if (!ask || !writable() || unanswered(ask).length || F.busy['ask']) return;
          F.busy['ask'] = true; F.errors['ask'] = null; updateBar();
          post({ type: 'answerAsk', askID: ask.askID, answers: ask.questions.map(q => answerFor(ask, q)) });
        }
        function cancel(){
          const ask = openAsk(); if (!ask || !writable() || F.busy['ask']) return;
          F.busy['ask'] = true; F.errors['ask'] = null; updateBar();
          post({ type: 'cancelAsk', askID: ask.askID });
        }
        function next(){
          const ask = openAsk(); if (!ask) return;
          const rest = unanswered(ask); if (rest.length) F.scrollTo(cardName(ask, rest[0]));
        }
        function updateBar(){
          const bar = document.getElementById('tb-forms-bar'); if (!bar) return;
          const ask = openAsk();
          if (!ask) { bar.hidden = true; document.body.classList.remove('tb-has-bar'); return; }
          bar.hidden = false; document.body.classList.add('tb-has-bar');
          const rest = unanswered(ask), busy = !!F.busy['ask'];
          const actions = el('div', 'tb-actions');
          const hint = el('span', 'tb-hint', F.errors['ask'] || F.data.blocked || (rest.length ? L('allRequired') : ''));
          if (F.errors['ask']) hint.classList.add('tb-error');
          actions.append(hint);
          if (rest.length && ask.questions.length > 1) { const n = el('button', 'tb-button', L('next')); n.type = 'button'; n.addEventListener('click', next); actions.append(n); }
          const c = el('button', 'tb-button', L('close')); c.type = 'button'; c.title = L('closeHelp'); c.disabled = busy || !writable(); c.addEventListener('click', cancel);
          const s = el('button', 'tb-button tb-primary', busy ? L('sending') : L('send')); s.type = 'button'; s.title = L('sendHelp');
          s.disabled = busy || rest.length > 0 || !writable(); s.addEventListener('click', send);
          actions.append(c, s);
          bar.replaceChildren(actions);
        }
        function render(){
          document.querySelectorAll('[data-tb-slot]').forEach(s => s.replaceChildren());
          const end = document.getElementById('tb-forms-end'); if (!end || !F.data) return;
          end.replaceChildren();
          for (const ask of F.data.asks) for (const q of ask.questions) { const card = questionCard(ask, q); ((ask.inBody && slot('ask:' + q.id)) || end).append(card); }
          for (const d of F.data.drafts) { const card = draftCard(d); (slot('draft:' + d.id) || end).append(card); }
          updateBar();
          if (F.pendingScroll) { const name = F.pendingScroll; F.pendingScroll = null; F.scrollTo(name); }
        }
        F.set = function(data){
          const before = openAsk();
          F.data = data;
          const now = openAsk();
          if (!now || (before && before.askID !== now.askID)) { F.busy['ask'] = false; }
          render(); pending();
        };
        F.result = function(kind, id, error){
          if (kind === 'ask') { F.busy['ask'] = false; F.errors['ask'] = error; updateBar(); }
          else { F.busy['draft:' + id] = false; F.errors['draft:' + id] = error; render(); }
        };
        F.scrollTo = function(name){
          const card = document.querySelector('[data-tb-card="' + CSS.escape(name) + '"]');
          if (!card) { F.pendingScroll = name; return false; }
          card.scrollIntoView({ block: 'center', behavior: 'smooth' });
          card.classList.add('tb-flash'); setTimeout(() => card.classList.remove('tb-flash'), 1200);
          return true;
        };
        F.firstOpen = function(){ const ask = openAsk(); if (ask && ask.questions.length) return cardName(ask, ask.questions[0]); const d = F.data && F.data.drafts.find(x => !x.approved); return d ? 'draft:' + d.id : null; };
        document.addEventListener('keydown', e => {
          if (e.key !== 'Enter' || !(e.metaKey || e.ctrlKey)) return;
          const card = document.activeElement && document.activeElement.closest('[data-tb-card^="draft:"]');
          if (card) { const id = card.dataset.tbCard.slice(6); const d = F.data && F.data.drafts.find(x => x.id === id); if (d && !d.approved) { e.preventDefault(); approveDraft(d); } return; }
          if (openAsk()) { e.preventDefault(); send(); }
        });
        })();
        """
}
