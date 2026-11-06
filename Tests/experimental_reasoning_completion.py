"""Isolated Qwen3.5 thinking experiment; not imported by production code.

Official references checked 2026-09-11:
https://huggingface.co/Qwen/Qwen3.5-9B#best-practices
https://huggingface.co/Qwen/Qwen3.5-9B/raw/main/chat_template.jinja

The existing llama-cpp-python 0.3.32 create_completion signature supports all
parameters below; repeat_penalty maps to llama.cpp penalty_repeat, and
presence_penalty maps to penalty_present. The runtime's penalty history window
is recorded, not silently changed. This is a bounded short-task experiment,
not equivalent to the vendor's long-context/output benchmark configuration.
"""
import inspect
import json


THINKING_SAMPLING = {
    "temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0,
    "presence_penalty": 1.5, "repeat_penalty": 1.0,
}


class EndThinking:
    """Stop after generated closing tokens, keeping them in returned text.

    llama_cpp stopping_criteria sees evaluated input before yielding the next
    sampled token. Unlike stop=['</think>'], it retains the observed delimiter.
    """
    def __init__(self, prompt_length, closing_tokens):
        self.prompt_length = prompt_length
        self.closing_tokens = list(closing_tokens)
        self.observed = False

    def __call__(self, input_ids, _scores):
        if self.observed:
            return True
        generated_length = len(input_ids) - self.prompt_length
        if generated_length >= len(self.closing_tokens):
            self.observed = list(input_ids[-len(self.closing_tokens):]) == self.closing_tokens
        return self.observed


def _runtime_parameters(llm):
    parameters = inspect.signature(llm.create_completion).parameters
    needed = set(THINKING_SAMPLING) | {"prompt", "max_tokens", "seed", "grammar", "stopping_criteria", "stop"}
    if not any(p.kind == inspect.Parameter.VAR_KEYWORD for p in parameters.values()):
        missing = needed - parameters.keys()
        if missing:
            raise ValueError("runtime does not support required parameters: " + ",".join(sorted(missing)))
    template = str(getattr(llm, "metadata", {}).get("tokenizer.chat_template", ""))
    if "enable_thinking" not in template or "<think>" not in template:
        raise ValueError("runtime has no Qwen thinking chat template")


def _grammar(schema):
    from llama_cpp import LlamaGrammar
    return LlamaGrammar.from_json_schema(json.dumps(schema, ensure_ascii=False), verbose=False)


def reasoning_completion(llm, system_prompt, user_prompt, schema, *, thinking_budget=3072,
                         final_budget=700, seed=20260911, margin=512, grammar_factory=None):
    """Return a diagnostic report, never synthesize an incomplete final answer.

    The final stage continues the SAME assistant after its complete <think>
    block. No source or reasoning suffix is truncated or moved into a user
    message. Calls consume exact pre-tokenized prompts, avoiding implicit BOS
    or EOS differences in context-budget accounting.
    """
    if type(thinking_budget) is not int or not 1 <= thinking_budget <= 3072:
        raise ValueError("thinking budget must be between 1 and 3072")
    if type(final_budget) is not int or not 1 <= final_budget <= 2048:
        raise ValueError("final budget must be between 1 and 2048")
    if type(seed) is not int or not 0 <= seed < 2 ** 32:
        raise ValueError("seed must be a fixed unsigned integer")
    if type(margin) is not int or margin < 512:
        raise ValueError("context safety margin must be at least 512")
    if not isinstance(system_prompt, str) or not isinstance(user_prompt, str) or not isinstance(schema, dict):
        raise ValueError("invalid experimental input")
    _runtime_parameters(llm)
    limit = min(8192, llm.n_ctx())
    prefix = ("<|im_start|>system\n" + system_prompt + "<|im_end|>\n"
              "<|im_start|>user\n" + user_prompt + "<|im_end|>\n"
              "<|im_start|>assistant\n<think>\n")
    tokens = llm.tokenize(prefix.encode("utf-8"), add_bos=True, special=True)
    sampling = dict(THINKING_SAMPLING, seed=seed)
    report = {"status": "pending", "value": None, "thinkingText": "", "finalText": "", "calls": [],
              "sampling": sampling, "contextLimit": limit, "margin": margin,
              "thinkingBudget": thinking_budget, "finalBudget": final_budget,
              "penaltyHistoryTokens": getattr(llm, "last_n_tokens_size", None)}
    # Reserve final-answer capacity before consuming any thinking budget.
    if len(tokens) + thinking_budget + final_budget + margin > limit:
        report.update(status="context_budget_exhausted", stage="thinking", promptTokens=len(tokens))
        return report
    closing = llm.tokenize(b"</think>", add_bos=False, special=True)
    if not closing:
        raise ValueError("runtime cannot tokenize the thinking delimiter")
    criterion = EndThinking(len(tokens), closing)
    response = llm.create_completion(prompt=tokens, max_tokens=thinking_budget,
                                     stopping_criteria=criterion, stop=[], **sampling)
    choice = response["choices"][0]
    thinking = choice.get("text") or ""
    report["thinkingText"] = thinking
    report["calls"].append({"stage": "thinking", "prompt": prefix, "promptTokens": len(tokens),
                            "completion": response, "maxTokens": thinking_budget})
    if "</think>" not in thinking:
        report.update(status="budget_exhausted", stage="thinking", reason="thinking_not_closed")
        return report
    before, after = thinking.split("</think>", 1)
    if after.strip() or "<think>" in before or "<|im_end|>" in before:
        report.update(status="protocol_error", stage="thinking", reason="unexpected_content_after_or_inside_thinking")
        return report
    # Preserve all original bytes; only add the template's answer separator.
    final_prompt = prefix + thinking + "\n\n"
    final_tokens = llm.tokenize(final_prompt.encode("utf-8"), add_bos=True, special=True)
    report["finalPromptTokens"] = len(final_tokens)
    if len(final_tokens) + final_budget + margin > limit:
        report.update(status="context_budget_exhausted", stage="final")
        return report
    grammar = (grammar_factory or _grammar)(schema)
    final_response = llm.create_completion(prompt=final_tokens, max_tokens=final_budget,
                                           grammar=grammar, stop=["<|im_end|>"], **sampling)
    final_choice = final_response["choices"][0]
    answer = final_choice.get("text") or ""
    report["finalText"] = answer
    report["calls"].append({"stage": "final", "prompt": final_prompt, "promptTokens": len(final_tokens),
                            "completion": final_response, "maxTokens": final_budget})
    if final_choice.get("finish_reason") == "length":
        report.update(status="budget_exhausted", stage="final", reason="final_output_budget_exhausted")
        return report
    try:
        value = json.loads(answer)
        if not isinstance(value, dict):
            raise ValueError("final answer must be a JSON object")
    except (ValueError, TypeError) as error:
        report.update(status="protocol_error", stage="final", reason=str(error))
        return report
    report.update(status="completed", value=value)
    return report
