"""Explicit opt-in Chat Completions transport, with separately approved images.

No SDK, local model, automatic provider fallback, redirect, or hidden retry.
Credentials enter through the child environment, never the manifest or logs.
"""
import json
import base64
import math
import os
import socket
import sys
import time
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


class RemoteAPIError(RuntimeError):
    pass


def endpoint_url(base):
    if not isinstance(base, str) or not base or any(c.isspace() for c in base):
        raise RemoteAPIError("请填写有效的 API 服务地址")
    try:
        parsed = urllib.parse.urlsplit(base)
        parsed.port
    except ValueError:
        raise RemoteAPIError("API 地址格式无效") from None
    if (not parsed.hostname or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment):
        raise RemoteAPIError("API 地址不能包含账号、密钥、查询参数或片段")
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")):
        raise RemoteAPIError("远程 API 必须使用 HTTPS；HTTP 仅限本机回环地址")
    base = base.rstrip("/")
    return base if base.endswith("/chat/completions") else base + "/chat/completions"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RemoteAPIError("API 返回重定向，已阻止转发密钥和文字；请填写最终服务地址")


def validate_shape(value, schema):
    """Validate the JSON-schema subset used by our text pipeline locally."""
    if "anyOf" in schema:
        for alternative in schema["anyOf"]:
            try:
                validate_shape(value, alternative)
                break
            except RemoteAPIError:
                continue
        else:
            raise RemoteAPIError("API 返回的字段不符合允许的类型，未采用结果")
    kind = schema.get("type")
    valid = {"object": isinstance(value, dict), "array": isinstance(value, list),
             "string": isinstance(value, str), "integer": type(value) is int,
             "number": type(value) in (int, float), "boolean": type(value) is bool,
             "null": value is None}
    if kind is not None and not valid.get(kind, False):
        raise RemoteAPIError("API 返回的 JSON 字段类型不符合要求，未采用结果")
    if "enum" in schema and not any(type(value) is type(v) and value == v for v in schema["enum"]):
        raise RemoteAPIError("API 返回了不允许的字段值，未采用结果")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        if not set(schema.get("required", [])) <= value.keys():
            raise RemoteAPIError("API 返回的 JSON 缺少必要字段，未采用结果")
        if schema.get("additionalProperties") is False and not value.keys() <= properties.keys():
            raise RemoteAPIError("API 返回了未定义字段，未采用结果")
        for name, item in value.items():
            if name in properties:
                validate_shape(item, properties[name])
    elif isinstance(value, list):
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", 100_000):
            raise RemoteAPIError("API 返回的条目数量不符合要求，未采用结果")
        for item in value:
            validate_shape(item, schema.get("items", {}))
    elif isinstance(value, str):
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 2_000_000):
            raise RemoteAPIError("API 返回的文本长度不符合要求，未采用结果")
    elif type(value) in (int, float):
        if not math.isfinite(value) or not schema.get("minimum", float("-inf")) <= value <= schema.get("maximum", float("inf")):
            raise RemoteAPIError("API 返回的数值超出范围，未采用结果")


class RemoteModel:
    is_remote = True
    metadata = {}

    def __init__(self, configuration, key=None, progress=None, *, image_mode=False):
        if not isinstance(configuration, dict):
            raise RemoteAPIError("请先在设置中配置 API")
        self.config = dict(configuration)
        base = self.config.get("baseURL")
        self.url = endpoint_url(base)
        self.image_mode = image_mode is True
        approval = "approvedImageEndpoint" if self.image_mode else "approvedEndpoint"
        if self.config.get(approval) != base:
            material = "图片" if self.image_mode else "文字"
            raise RemoteAPIError(f"尚未同意向当前 API 服务发送{material}，请先在设置中确认")
        self.model = self.config.get("model")
        if not isinstance(self.model, str) or not 1 <= len(self.model) <= 160 or any(c.isspace() for c in self.model):
            raise RemoteAPIError("请填写有效的 API 模型名称")
        variable = "KNOWLEDGE_SPINE_IMAGE_API_KEY" if self.image_mode else "KNOWLEDGE_SPINE_API_KEY"
        self.key = key if key is not None else os.environ.get(variable, "")
        if not self.key or any(c in self.key for c in "\r\n") or len(self.key) > 8192:
            raise RemoteAPIError("未取得有效 API Key，请在设置中保存密钥")
        self.context = self.config.get("contextWindow", 32768)
        self.output = self.config.get("maxOutputTokens", 4096)
        if (type(self.context) is not int or not 8192 <= self.context <= 1_000_000
                or type(self.output) is not int or not 256 <= self.output <= 32768
                or self.output >= self.context - 1024):
            raise RemoteAPIError("API 上下文或输出预算配置无效")
        self.limit_field = self.config.get("tokenLimitField", "max_tokens")
        if self.limit_field not in ("max_tokens", "max_completion_tokens"):
            raise RemoteAPIError("API 输出预算参数无效")
        self.thinking = self.config.get("thinkingMode")
        if self.thinking not in (None, "enabled", "disabled"):
            raise RemoteAPIError("API 思考模式配置无效")
        if type(self.config.get("jsonMode", True)) is not bool:
            raise RemoteAPIError("API JSON 模式配置无效")
        self.progress, self.calls = progress, 0
        self.opener = urllib.request.build_opener(NoRedirect())

    def tokenize(self, data, **kwargs):
        # Conservative UTF-8 byte estimate, not a claim to know remote tokens.
        return range(len(data))

    def n_ctx(self):
        # Existing callers additionally reserve their local-stage reply budget.
        return self.context - self.output

    def close(self):
        self.key = ""

    def structured(self, system, prompt, schema, **sampling):
        if self.calls >= 128:
            raise RemoteAPIError("本次任务已达到 128 次 API 请求上限，已停止；没有自动追加调用")
        text = prompt + "\n只输出符合以下结构的 JSON，不要附加说明：" + json.dumps(schema, ensure_ascii=False, separators=(",", ":"))
        images = sampling.pop("image_inputs", None)
        if images is not None and (not self.image_mode or not isinstance(images, list) or not 1 <= len(images) <= 9):
            raise RemoteAPIError("图片请求必须使用单独授权的识图模型，且每次最多1张总览及8张细节图")
        messages = [{"role": "system", "content": system}, {"role": "user", "content": text}]
        if len(json.dumps(messages, ensure_ascii=False).encode()) + self.output + 512 > self.context:
            raise RemoteAPIError("文字超过当前 API 上下文预算，未截断发送；请检查上下文设置")
        if images:
            if len(text.encode()) + len(system.encode()) + self.output + 512 + len(images) * 2048 > self.context:
                raise RemoteAPIError("图文超过当前识图模型上下文预算，未截断发送")
            parts = [{"type": "text", "text": text}]
            for item in images:
                if (not isinstance(item, dict) or item.get("mimeType") not in ("image/jpeg", "image/png")
                        or not isinstance(item.get("data"), bytes) or not 1 <= len(item["data"]) <= 10_000_000):
                    raise RemoteAPIError("识图输入必须是经过校验的本地 JPEG 或 PNG，单张不超过10MB")
                encoded = base64.b64encode(item["data"]).decode("ascii")
                parts.append({"type": "image_url", "image_url": {"url": f"data:{item['mimeType']};base64,{encoded}"}})
            messages[1]["content"] = parts
        payload = {"model": self.model, "messages": messages, "stream": False,
                   self.limit_field: self.output}
        if self.config.get("jsonMode", True):
            payload["response_format"] = {"type": "json_object"}
        if self.thinking is not None:
            payload["thinking"] = {"type": self.thinking}
        focused = sampling.get("api_task") == "focused-study"
        # DeepSeek's documented default is high effort. A bounded low-effort
        # reasoning pass leaves space for the actual answer in this single call.
        if (focused and urllib.parse.urlsplit(self.url).hostname == "api.deepseek.com"
                and self.thinking != "disabled"):
            payload["reasoning_effort"] = "low"
        # Do not forward llama-specific sampling or force local reasoning caps
        # onto remote providers. Provider defaults handle temperature/reasoning.
        self.calls += 1
        progress = sampling.get("progress_callback") or self.progress
        if progress:
            task = "分析图片" if images else "整理文字"
            progress(f"正在调用 API {task} · 第 {self.calls} 次请求（不发送音频）")
        request = urllib.request.Request(self.url, data=json.dumps(payload, ensure_ascii=False).encode(),
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"}, method="POST")
        started = time.monotonic()
        try:
            with self.opener.open(request, timeout=300 if focused else 120) as response:
                body = response.read(2_000_001)
                if len(body) > 2_000_000:
                    raise RemoteAPIError("API 响应超过安全大小，未采用结果")
        except urllib.error.HTTPError as error:
            messages = {401: "API Key 无效或已失效", 403: "API 无访问权限",
                        404: "API 地址或模型不存在", 429: "API 额度不足或请求过于频繁",
                        400: "API 不接受当前模型或参数，请检查模型名、JSON 模式和输出预算参数"}
            raise RemoteAPIError(messages.get(error.code, f"API 服务返回 HTTP {error.code}，未自动重试")) from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError):
            raise RemoteAPIError("API 连接失败或超时，未自动重试；原稿和已有结果保留") from None
        checkpoint = getattr(self, "response_checkpoint_path", None)
        if checkpoint:
            # Private, local recovery material, never displayed as a completed
            # report and never written to ordinary logs. Redact an echoed key.
            path = Path(checkpoint)
            temporary = path.with_suffix(".tmp")
            with temporary.open("w", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                handle.write(body.decode("utf-8", errors="replace").replace(self.key, "[redacted]"))
            temporary.replace(path)
        try:
            response = json.loads(body)
            choice = response["choices"][0]
            if not isinstance(choice, dict) or not isinstance(choice.get("message"), dict):
                raise ValueError("Invalid response envelope")
            reason = choice.get("finish_reason")
            known = {"stop", "length", "content_filter", "tool_calls", "insufficient_system_resource", "aborted"}
            safe_reason = reason if isinstance(reason, str) and reason in known else "unknown"
            usage = response.get("usage") or {}
            metrics = {"call": self.calls, "finish_reason": safe_reason,
                       "seconds": round(time.monotonic() - started, 2)}
            if isinstance(usage, dict):
                for name in ("prompt_tokens", "completion_tokens", "total_tokens"):
                    if type(usage.get(name)) is int and usage[name] >= 0:
                        metrics[name] = usage[name]
                details = usage.get("completion_tokens_details")
                if isinstance(details, dict) and type(details.get("reasoning_tokens")) is int:
                    metrics["reasoning_tokens"] = max(0, details["reasoning_tokens"])
            print("API_METRICS " + json.dumps(metrics), file=sys.stderr, flush=True)
            if reason != "stop" or choice["message"].get("tool_calls") or choice["message"].get("refusal"):
                explanations = {"length": "API 达到输出上限，答案被截断；请提高最大输出预算后重新整理",
                    "content_filter": "API 服务拦截了本次回答", "tool_calls": "API 返回工具调用而非答案",
                    "insufficient_system_resource": "API 服务计算资源不足，中断了回答",
                    "aborted": "API 服务中断了回答"}
                detail = ("API 服务拒绝了本次回答" if choice["message"].get("refusal") else
                          explanations.get(safe_reason, "API 未返回完整答案"))
                suffix = "；已保存本次响应检查点，未将截断内容当成完整答案" if checkpoint else "；未采用半份结果"
                raise RemoteAPIError(f"{detail}（finish_reason={safe_reason}）{suffix}")
            content = choice["message"].get("content")
            if not isinstance(content, str) or not content.strip():
                raise RemoteAPIError("API 没有返回可用正文，未采用结果")
            content = content.strip()
            if content.startswith("```json\n") and content.endswith("\n```"):
                content = content[8:-4]
            value = json.loads(content)
            validate_shape(value, schema)
            return value
        except (ValueError, TypeError, KeyError, IndexError, RecursionError):
            # Never expose the provider body, which may echo prompts or keys.
            raise RemoteAPIError("API 返回的内容不是有效的结构化答案，未采用结果") from None

    def probe(self):
        self.output = 256
        if self.thinking is not None:
            self.thinking = "disabled"
        answer = self.structured("这是接口连接测试。只输出JSON。", '请返回 {"ok":true}。',
            {"type": "object", "properties": {"ok": {"type": "boolean", "enum": [True]}},
             "required": ["ok"], "additionalProperties": False})
        return answer["ok"] is True
