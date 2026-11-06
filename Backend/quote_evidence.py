"""Exact-quote protocol used by the development pipeline's semantic gate.

Offsets and UUIDs are derived by code, never trusted from a model. Exact quotes
are evidence locations, not a proof that a natural-language claim is true.
"""
import json
import re
from dataclasses import dataclass, replace


class QuoteError(ValueError):
    pass


@dataclass(frozen=True)
class LocatedQuote:
    text: str
    source_ids: tuple
    start: int
    end: int
    context: str
    requested_quote: str
    requested_start: int
    requested_end: int
    expanded: bool = False
    whitespace_normalized: bool = False


class ManuscriptIndex:
    def __init__(self, records):
        self.ranges, pieces = [], []
        position, previous, seen = 0, None, set()
        for ordinal, record in enumerate(records):
            identifier, text = record["id"], record["text"]
            sequence = record.get("sequence", ordinal)
            if identifier in seen or not isinstance(text, str) or "\0" in text:
                raise QuoteError("duplicate source ID or invalid source text")
            seen.add(identifier)
            if previous is not None and sequence != previous + 1:
                pieces.append("\0")  # Never join non-contiguous source fragments.
                position += 1
            pieces.append(text)
            self.ranges.append((position, position + len(text), identifier))
            position += len(text)
            previous = sequence
        self.text = "".join(pieces)
        # Decimal dots are not sentence boundaries. Commas/colons are never
        # boundaries: conditions and negations often appear after them.
        self.boundaries = {0, len(self.text)}
        for match in re.finditer(r"[。！？!?；;\n\0]|(?<!\d)\.(?!\d)", self.text):
            end = match.end()
            while end < len(self.text) and self.text[end] in "’”'\"）)]":
                end += 1
            self.boundaries.add(end)
        self.boundaries = sorted(self.boundaries)

    def sentences(self):
        return [self.text[a:b].strip("\0\n \t") for a, b in zip(self.boundaries, self.boundaries[1:])
                if self.text[a:b].strip("\0\n \t")]

    def _unique_range(self, quote):
        if not isinstance(quote, str) or not quote.strip() or "\0" in quote:
            raise QuoteError("empty or invalid quote")
        found, cursor = [], 0
        while True:
            cursor = self.text.find(quote, cursor)
            if cursor < 0:
                break
            found.append(cursor)
            cursor += 1
        if len(found) != 1:
            raise QuoteError("quote not found exactly once")
        return found[0], found[0] + len(quote)

    def recover(self, quote):
        """Resolve a unique literal fragment, explicitly returning its full unit.

        This does not approve the fragment as evidence or fix its meaning. The
        expanded ORIGINAL sentence must still pass locate() and semantic review.
        """
        try:
            start, end = self._unique_range(quote)
            whitespace_normalized = False
        except QuoteError:
            # Ambiguous literal text is never rescued by normalization. Only
            # a zero-match, valid request may retry typography-only matching.
            if not isinstance(quote, str) or not quote.strip() or "\0" in quote or quote in self.text:
                raise
            start, end = self._whitespace_range(quote)
            whitespace_normalized = True
        requested_start, requested_end = start, end
        actual = self.text[start:end]
        try:
            located = self.locate(actual)
        except QuoteError:
            left = max(b for b in self.boundaries if b <= start)
            right = min(b for b in self.boundaries if b >= end)
            whole = self.text[left:right].strip("\0\n \t")
            located = self.locate(whole)
        return replace(located, requested_quote=quote, requested_start=requested_start,
                       requested_end=requested_end, expanded=(located.start, located.end) != (start, end),
                       whitespace_normalized=whitespace_normalized)

    def _whitespace_range(self, quote):
        if any(c in quote for c in "\0\n\r\u2028\u2029"):
            raise QuoteError("whitespace fallback cannot cross a paragraph or source gap")
        normalized, starts, ends = normalize_horizontal_space(self.text)
        requested, _, _ = normalize_horizontal_space(quote)
        if not requested:
            raise QuoteError("empty normalized quote")
        found, cursor = [], 0
        while True:
            cursor = normalized.find(requested, cursor)
            if cursor < 0:
                break
            found.append(cursor)
            cursor += 1
        if len(found) != 1:
            raise QuoteError("whitespace-normalized quote not found exactly once")
        position = found[0]
        return starts[position], ends[position + len(requested) - 1]

    def locate(self, quote):
        """Strict final quote validation, with no silent sentence expansion."""
        start, end = self._unique_range(quote)
        left = max(b for b in self.boundaries if b <= start)
        right = min(b for b in self.boundaries if b >= end)
        # A partial sentence can omit a negation or a condition. Do not repair
        # a copied fragment silently; ask for a complete original sentence.
        prefix = self.text[left:start].strip("\0\n \t")
        suffix = self.text[end:right].strip("\0\n \t。！？!?；;.’”'\"）)]")
        if prefix or suffix:
            raise QuoteError("quote clips a sentence, condition, or negation")
        ids = tuple(identifier for a, b, identifier in self.ranges if a < end and b > start)
        before = max((b for b in self.boundaries if b < left), default=left)
        after = min((b for b in self.boundaries if b > right), default=right)
        # Neighbour sentences are visible to the semantic judge, so selecting
        # a complete positive sentence does not hide a following qualification.
        # A missing source interval is not punctuation. Never borrow a fragment
        # from its opposite side and accidentally attach its negation/subject.
        previous_gap = self.text.rfind("\0", 0, start)
        next_gap = self.text.find("\0", end)
        before = max(before, previous_gap + 1)
        if next_gap >= 0:
            after = min(after, next_gap)
        context = self.text[before:after]
        return LocatedQuote(quote, ids, start, end, context, quote, start, end)


def quote_audit(match):
    return {"requestedQuote": match.requested_quote, "requestedStart": match.requested_start,
            "requestedEnd": match.requested_end, "expanded": match.expanded,
            "quote": match.text, "start": match.start, "end": match.end,
            "sourceSpanIDs": list(match.source_ids), "whitespaceNormalized": match.whitespace_normalized}


def normalize_horizontal_space(text):
    """Typography-only lookup with a reversible character-range map.

    Only a non-numeric Han character or text edge permits dropping space.
    All other token separators (including Unicode digits/letters/combining
    marks and decimal punctuation) remain; line/source gaps are never erased.
    """
    horizontal = " \t\u00a0\u3000"
    output, starts, ends = [], [], []
    i = 0
    while i < len(text):
        if text[i] not in horizontal:
            output.append(text[i]); starts.append(i); ends.append(i + 1)
            i += 1
            continue
        end = i + 1
        while end < len(text) and text[end] in horizontal:
            end += 1
        left = text[i - 1] if i else ""
        right = text[end] if end < len(text) else ""
        def han(character):
            if not character or character.isnumeric():
                return False
            code = ord(character)
            return (0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF
                    or 0xF900 <= code <= 0xFAFF or 0x20000 <= code <= 0x2FA1F
                    or 0x30000 <= code <= 0x323AF)
        if left and right and not (han(left) or han(right)):
            output.append(" "); starts.append(i); ends.append(end)
        i = end
    return "".join(output), starts, ends


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _fits(llm, system, prompt, schema, reply):
    if not hasattr(llm, "tokenize") or not hasattr(llm, "n_ctx"):
        return len((system + prompt + _json(schema)).encode()) <= 16000
    return len(llm.tokenize((system + prompt + _json(schema)).encode())) + reply + 512 <= llm.n_ctx()


def retrieve_quotes(llm, complete, claims, index):
    """Read source once per node/page, not once for each atomic claim."""
    if not claims or len(claims) > 8:
        raise QuoteError("a node must contain one to eight claims")
    item = {"type": "object", "properties": {
        "claimIndex": {"type": "integer", "enum": list(range(len(claims)))},
        "quotes": {"type": "array", "maxItems": 3, "items": {"type": "string", "minLength": 1, "maxLength": 600}}},
        "required": ["claimIndex", "quotes"]}
    schema = {"type": "object", "properties": {"evidence": {"type": "array", "maxItems": len(claims), "items": item}}, "required": ["evidence"]}
    system = "你只复制与原主张直接相关的原文完整句，不改写、不判断真假、不返回来源编号。只输出JSON。"
    def prompt_for(sentences):
        return ("为每条原主张选取最多3句最直接的原文，支持或反驳都应保留。quotes必须逐字复制完整句，连同否定、条件与转折；不能改繁简字、数字或标点。"
                "不确定或没有相关原话则quotes为空。重复句需包含足够连续原文使摘录唯一，不得用解释代替引用。每个claimIndex最多一次。输入："
                + _json({"claims": claims, "originalSentences": sentences}))
    pages, current = [], []
    for sentence in index.sentences():
        if current and not _fits(llm, system, prompt_for(current + [sentence]), schema, 2048):
            pages.append(current)
            current = []
        if not _fits(llm, system, prompt_for([sentence]), schema, 2048):
            raise QuoteError("one complete source sentence exceeds retrieval context; not truncated")
        current.append(sentence)
    if current:
        pages.append(current)
    located, errors = {i: [] for i in range(len(claims))}, []
    for page in pages:
        payload = complete(llm, system, prompt_for(page), schema, max_tokens=2048, temperature=0.0)
        entries = payload.get("evidence") if isinstance(payload, dict) else None
        if not isinstance(entries, list) or len(entries) > len(claims):
            raise QuoteError("invalid retrieval response")
        seen = set()
        page_text = "".join(page)
        for entry in entries:
            if not isinstance(entry, dict):
                raise QuoteError("invalid evidence entry")
            i, quotes = entry.get("claimIndex"), entry.get("quotes")
            if type(i) is not int or i not in located or i in seen or not isinstance(quotes, list) or len(quotes) > 3:
                raise QuoteError("invalid or repeated claim index")
            seen.add(i)
            for quote in quotes:
                try:
                    match = index.recover(quote)
                    requested_original = index.text[match.requested_start:match.requested_end]
                    if requested_original not in page_text:
                        raise QuoteError("quote was not present in this retrieval page")
                    if match not in located[i]:
                        located[i].append(match)
                except QuoteError as error:
                    errors.append({"claimIndex": i, "error": str(error)})
    return located, errors


def judge_claim(llm, complete, claim, matches, index, *, semantic_role="assertion", scope_notes=None):
    """Judge a short literal claim against located text, not guessed IDs."""
    if not matches:
        return {"verdict": "unknown", "sourceSpanIDs": [], "reason": "没有唯一完整的原文摘录"}
    if semantic_role not in ("assertion", "topic"):
        raise QuoteError("unknown semantic role")
    if semantic_role == "topic" and (not isinstance(scope_notes, list) or not scope_notes):
        raise QuoteError("a topic requires the complete lesson scope")
    contexts = list(dict.fromkeys(m.context for m in matches))
    schema = {"type": "object", "properties": {
        "verdict": {"type": "string", "enum": ["supported", "contradicted", "unknown"]},
        "claimQuote": {"type": "string", "enum": [claim]},
        "evidenceQuotes": {"type": "array", "maxItems": 3, "items": {"type": "string", "maxLength": 600}},
        "assumptions": {"type": "array", "maxItems": 2, "items": {"type": "string", "maxLength": 100}},
        "reason": {"type": "string", "minLength": 1, "maxLength": 140}},
        "required": ["verdict", "claimQuote", "evidenceQuotes", "assumptions", "reason"]}
    system = "你是原主张与原文的逻辑核验员，不得替原主张补前提。只输出JSON。"
    prompt = ("原主张就是claimQuote里的原字，不是你联想到的含义。supported需要原文支持主张全部必要含义；contradicted要求原主张与原文不可能同时为真；"
              "两者能同时为真、但缺少支持，只能unknown，不能用缺证作反证。若结论需要给原主张添加隐含前提，必须列入assumptions并判unknown。"
              "主体、否定、条件、数量、因果、个人经验边界不能改变。用evidenceQuotes逐字复制支持判断的完整原文句，保留邻句限定。"
              "contradicted的reason必须指出原主张原字与原文之间的真实冲突，不得反驳原主张没有说过的前提。"
              "claimQuote必须完整复制原主张，不能换成自己的释义。输入：" + _json({"claimQuote": claim, "sourceContexts": contexts}))
    if semantic_role == "topic":
        # In this role, collect literal evidence and explain the issue before
        # committing to a verdict. Keep assertion grammar unchanged. Property
        # order affects llama.cpp's constrained generation, not just JSON style.
        schema["properties"] = {key: schema["properties"][key] for key in
                                ("claimQuote", "evidenceQuotes", "assumptions", "reason", "verdict")}
        system = "你是整课主题与原文的核验员，区分议题和已经成立的事实；不得替标题添加或免除前提。只输出JSON。"
        prompt = ("claimQuote是整课中心主题，不要求课程已经得出最终答案。supported须同时满足两点："
                  "一、scopeNotes所覆盖的全课主要论述确实围绕这个主题，不能拿开头寒暄、旁题或一处提及冒充中心，也不能用空泛分享充当准确主题；"
                  "二、标题自身包含的全部预设、主体、数字、程度、因果及采用/有效等含义，均须由sourceContexts真实原文支持。"
                  "疑问式或‘讨论了’措辞不能免除其事实预设，谈过或引用后否定一种方案，不等于采用它或承认其优势。"
                  "scopeNotes是覆盖全课的已核验论述范围元数据，只帮助判断主次，不能替代sourceContexts作事实证据。"
                  "不得把议题未决当成矛盾；缺证是unknown，明确冲突才是contradicted。不要新增常识、主体、隐含前提或确定结论。"
                  "claimQuote原字完整保留；evidenceQuotes必须逐字复制sourceContexts内足以支持判断的完整原句，保留条件、否定、说话主体。"
                  "如需附加前提，列入assumptions并判unknown；contradicted的reason必须指出标题实际含义与原文的冲突。输入："
                  + _json({"claimQuote": claim, "sourceContexts": contexts, "scopeNotes": scope_notes}))
    if not _fits(llm, system, prompt, schema, 700):
        return {"verdict": "unknown", "sourceSpanIDs": [], "reason": "完整证据上下文超过判义预算，未截断"}
    def validate(value):
        if not isinstance(value, dict) or value.get("claimQuote") != claim or value.get("verdict") not in ("supported", "contradicted", "unknown"):
            raise QuoteError("judge changed the original claim or returned an invalid verdict")
        assumptions, quotes = value.get("assumptions"), value.get("evidenceQuotes")
        if (not isinstance(assumptions, list) or len(assumptions) > 2 or any(not isinstance(a, str) for a in assumptions)
                or not isinstance(quotes, list) or len(quotes) > 3
                or not isinstance(value.get("reason"), str) or not 1 <= len(value["reason"].strip()) <= 140):
            raise QuoteError("invalid judge evidence protocol")
    value = complete(llm, system, prompt, schema, max_tokens=700, temperature=0.0)
    validate(value)
    assumptions, quotes = value["assumptions"], value["evidenceQuotes"]
    verdict = value["verdict"]
    if assumptions:
        verdict = "unknown"
    resolved = []
    for quote in quotes:
        match = index.recover(quote)
        index.locate(match.text)  # Explicit final evidence validation.
        if not any(match.text in context for context in contexts):
            raise QuoteError("judge evidence was not shown in its context")
        resolved.append(match)
    if verdict != "unknown" and not resolved:
        raise QuoteError("a positive or negative verdict requires actual quotes")
    return {"verdict": verdict, "sourceSpanIDs": list(dict.fromkeys(i for m in resolved for i in m.source_ids)),
            "quotes": [m.text for m in resolved], "quoteAudit": [quote_audit(m) for m in resolved],
            "reason": value.get("reason", ""), "assumptions": assumptions}


def verify_node(llm, complete, claims, records, *, semantic_role="assertion", scope_notes=None):
    if semantic_role not in ("assertion", "topic"):
        raise QuoteError("unknown semantic role")
    if semantic_role == "topic" and (len(claims) != 1 or not isinstance(scope_notes, list) or not scope_notes):
        raise QuoteError("a topic requires one title and the complete lesson scope")
    index = ManuscriptIndex(records)
    located, errors = retrieve_quotes(llm, complete, claims, index)
    # Claims of one node may need complementary passages. Retrieval ownership
    # is an audit fact, not a restriction on what the same node's judge may see.
    # This pool is local to this invocation; it cannot leak to another node.
    pooled = {}
    for matches in located.values():
        for match in matches:
            pooled.setdefault((match.start, match.end), match)
    shared_matches = list(pooled.values())
    judgments = []
    for i, claim in enumerate(claims):
        # Invalid/ambiguous retrieval is not replaced by an invented location.
        if any(error["claimIndex"] == i for error in errors):
            judgments.append({"claimIndex": i, "claim": claim, "verdict": "unknown", "sourceSpanIDs": [],
                              "reason": "至少一条取证摘录无法唯一完整定位，未忽略该证据"})
            continue
        try:
            judgment = judge_claim(llm, complete, claim, shared_matches, index,
                                   semantic_role=semantic_role, scope_notes=scope_notes)
        except QuoteError as error:
            judgment = {"verdict": "unknown", "sourceSpanIDs": [], "reason": str(error)}
        judgments.append(dict(judgment, claimIndex=i, claim=claim, retrievalQuoteAudit=[quote_audit(m) for m in located[i]]))
    return {"judgments": judgments, "quoteErrors": errors,
            "semanticRole": semantic_role,
            "sharedRetrievalQuoteAudit": [quote_audit(m) for m in shared_matches]}


def verify_topic(llm, complete, title, records, scope_notes):
    """Public isolated-test entrypoint; same two model stages, no extra audit."""
    return verify_node(llm, complete, [title], records, semantic_role="topic", scope_notes=scope_notes)
