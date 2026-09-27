#!/usr/bin/env python3
"""Cloud-assist proxy for broad produce labels (standard library only).

The iPhone sends one downscaled JPEG crop plus the allowed MVP labels. This
server adds the Google AI Studio (Gemini API) key, asks Gemini for exactly one
label from that list, and returns {"label", "confidence", "model"}. Images are
never written to disk or logged.

Environment:
  GEMINI_API_KEY   Google AI Studio key; required unless CLOUD_PROXY_MOCK_LABEL is set
  GEMINI_MODEL     default gemini-3.1-flash-lite
  PROXY_TOKEN      optional; when set, clients must send "Authorization: Bearer <token>"
  CLOUD_PROXY_MOCK_LABEL  e.g. "onion": answer without calling Gemini (connection tests)
  HOST / PORT      default 0.0.0.0 / 8787
"""

import base64
import hmac
import json
import os
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
BLOCKED_FINISH_REASONS = {"SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "IMAGE_SAFETY", "SPII", "RECITATION"}
MAX_IMAGE_BYTES = 2 * 1024 * 1024
MAX_BODY_BYTES = 4 * 1024 * 1024
LABEL_PATTERN = re.compile(r"^[a-z][a-z_]{0,31}$")

PROMPT = (
    "You label grocery produce for a shopping assistant. Look at the single most "
    "prominent item in the photo. Answer with one broad category from the allowed "
    "labels only: say 'onion' for any onion (yellow, red, white, sweet), 'apple' for "
    "any apple variety, and so on. Bagged loose produce counts as that produce. "
    "Answer 'unknown' if no produce is clearly visible, if several different kinds "
    "are equally prominent, or if the item is packaged food that merely shows a "
    "picture of produce (cereal, snacks, juice). confidence is 0 to 1."
)


class ProxyError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def parse_request(body):
    try:
        payload = json.loads(body)
        labels = payload["labels"]
        image = base64.b64decode(payload["image_base64"], validate=True)
    except (ValueError, KeyError, TypeError) as error:
        raise ProxyError(400, f"invalid request: {error}")
    if (not isinstance(labels, list) or not 1 <= len(labels) <= 64 or "unknown" not in labels
            or not all(isinstance(label, str) and LABEL_PATTERN.match(label) for label in labels)):
        raise ProxyError(400, "labels must be 1-64 lowercase identifiers including 'unknown'")
    if not image.startswith(b"\xff\xd8") or len(image) > MAX_IMAGE_BYTES:
        raise ProxyError(400, "image must be a JPEG of at most 2 MB")
    return image, sorted(set(labels))


def build_gemini_request(image, labels):
    return {
        "contents": [{
            "role": "user",
            "parts": [
                {"text": PROMPT},
                {"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(image).decode()}},
            ],
        }],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseJsonSchema": {
                "type": "object",
                "properties": {
                    "label": {"type": "string", "enum": labels},
                    "confidence": {"type": "number"},
                },
                "required": ["label", "confidence"],
            },
        },
    }


def parse_gemini_response(response, labels, model):
    """Return the proxy answer. Safety blocks become 'unknown'; malformed output is an error."""
    unknown = {"label": "unknown", "confidence": 0.0, "model": model}
    if response.get("promptFeedback", {}).get("blockReason"):
        return unknown
    candidates = response.get("candidates") or []
    if candidates and candidates[0].get("finishReason") in BLOCKED_FINISH_REASONS:
        return unknown
    parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
    text = "".join(part.get("text", "") for part in parts if not part.get("thought"))
    try:
        answer = json.loads(text)
        label, confidence = answer["label"], float(answer["confidence"])
    except (ValueError, KeyError, TypeError):
        raise ProxyError(502, "upstream returned no valid label")
    if label not in labels or not 0 <= confidence <= 1:
        raise ProxyError(502, "upstream returned no valid label")
    return {"label": label, "confidence": confidence, "model": response.get("modelVersion", model)}


def call_gemini(request, api_key, model):
    upstream = urllib.request.Request(
        GEMINI_URL.format(model=model), data=json.dumps(request).encode(), method="POST",
        headers={"x-goog-api-key": api_key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(upstream, timeout=10) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            detail = json.load(error).get("error", {}).get("message", "")
        except ValueError:
            detail = ""
        finally:
            error.close()
        raise ProxyError(502, f"upstream HTTP {error.code} {detail[:300]}".strip())
    except (urllib.error.URLError, TimeoutError) as error:
        raise ProxyError(504, f"upstream unavailable: {error}")


def label_image(body, config, send=call_gemini):
    image, labels = parse_request(body)
    mock = config.get("mock_label")
    if mock:
        return {"label": mock if mock in labels else "unknown", "confidence": 0.95, "model": "mock"}
    request = build_gemini_request(image, labels)
    return parse_gemini_response(send(request, config["api_key"], config["model"]), labels, config["model"])


def make_handler(config, send=call_gemini):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/healthz":
                model = "mock" if config.get("mock_label") else config.get("model") or "gemini-3.1-flash-lite"
                self._reply(200, {"ok": True, "mock": bool(config.get("mock_label")), "model": model})
            else:
                self._reply(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/produce-label":
                return self._reply(404, {"error": "not found"})
            token = config.get("token")
            if token and not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                return self._reply(401, {"error": "unauthorized"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY_BYTES:
                return self._reply(413, {"error": "body too large or empty"})
            try:
                self._reply(200, label_image(self.rfile.read(length), config, send))
            except ProxyError as error:
                self._reply(error.status, {"error": str(error)})

        def log_message(self, format, *args):
            # Request line and status only; bodies (images) are never logged.
            print(f"{self.address_string()} {format % args}")

    return Handler


def main():
    config = {
        "api_key": os.environ.get("GEMINI_API_KEY", ""),
        "model": os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite"),
        "token": os.environ.get("PROXY_TOKEN", ""),
        "mock_label": os.environ.get("CLOUD_PROXY_MOCK_LABEL", ""),
    }
    if not config["api_key"] and not config["mock_label"]:
        raise SystemExit("Set GEMINI_API_KEY (Google AI Studio), or CLOUD_PROXY_MOCK_LABEL=onion for a connection test.")
    host, port = os.environ.get("HOST", "0.0.0.0"), int(os.environ.get("PORT", "8787"))
    mode = f"mock label '{config['mock_label']}'" if config["mock_label"] else f"model {config['model']}"
    print(f"Cloud assist proxy on http://{host}:{port}/v1/produce-label ({mode})")
    ThreadingHTTPServer((host, port), make_handler(config)).serve_forever()


if __name__ == "__main__":
    main()
