import json


def quote_response(prompt, schema, select=None, verdict="supported"):
    """Deterministic protocol fixture; never used by the real model harness."""
    properties = schema["properties"]
    if "evidence" in properties:
        data = json.loads(prompt.split("输入：", 1)[1])
        def pick(claim):
            return select(claim, data["originalSentences"]) if select else data["originalSentences"][:1]
        return {"evidence": [{"claimIndex": i, "quotes": pick(claim)} for i, claim in enumerate(data["claims"])]}
    if "verdict" in properties:
        data = json.loads(prompt.split("输入：", 1)[1])
        quotes = select(data["claimQuote"], data["sourceContexts"]) if select else data["sourceContexts"][:1]
        return {"verdict": verdict, "claimQuote": data["claimQuote"], "evidenceQuotes": quotes,
                "assumptions": [], "reason": "核对完整原文中的主体和条件"}
    return None
