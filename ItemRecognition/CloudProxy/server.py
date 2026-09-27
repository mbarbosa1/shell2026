#!/usr/bin/env python3
"""Cloud-assist proxy for Gemini (standard library only).

POST /v1/produce-label: the iPhone sends one downscaled JPEG crop plus the
allowed MVP labels; the server asks Gemini for exactly one label from that list
and returns {"label", "confidence", "model"}.

POST /v1/self-checkout: the iPhone sends one downscaled camera frame; the
server asks Gemini whether a self-checkout machine is in it and returns
{"found", "box", "confidence", "model"}, box being [ymin, xmin, ymax, xmax] as
0-1 fractions of the image (or null).

The server adds the Google AI Studio (Gemini API) key. Images are never written
to disk or logged.

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

CHECKOUT_PROMPT = (
    "You help a blind shopper find a store's self-checkout machines. A self-checkout is a "
    "self-service register: a touchscreen kiosk with a barcode scanner and a card reader, usually "
    "with a bagging area and often under a 'Self Checkout' sign. Staffed registers with a cashier, "
    "ATMs, vending machines, price checkers and photo kiosks are not self-checkouts. Is a "
    "self-checkout machine visible in the photo? If so, give box_2d for the nearest one as "
    "[ymin, xmin, ymax, xmax], each from 0 to 1000 across the image. confidence is 0 to 1."
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


def parse_checkout_request(body):
    try:
        image = base64.b64decode(json.loads(body)["image_base64"], validate=True)
    except (ValueError, KeyError, TypeError) as error:
        raise ProxyError(400, f"invalid request: {error}")
    if not image.startswith(b"\xff\xd8") or len(image) > MAX_IMAGE_BYTES:
        raise ProxyError(400, "image must be a JPEG of at most 2 MB")
    return image


def gemini_request(prompt, image, schema):
    """One generateContent call: the prompt, the JPEG, and a JSON schema the answer must follow."""
    return {
        "contents": [{
            "role": "user",
            "parts": [
                {"text": prompt},
                {"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(image).decode()}},
            ],
        }],
        "generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": schema},
    }


def build_gemini_request(image, labels):
    return gemini_request(PROMPT, image, {
        "type": "object",
        "properties": {
            "label": {"type": "string", "enum": labels},
            "confidence": {"type": "number"},
        },
        "required": ["label", "confidence"],
    })


def build_checkout_request(image):
    return gemini_request(CHECKOUT_PROMPT, image, {
        "type": "object",
        "properties": {
            "found": {"type": "boolean"},
            "box_2d": {"type": "array", "items": {"type": "integer"}, "minItems": 4, "maxItems": 4},
            "confidence": {"type": "number"},
        },
        "required": ["found", "confidence"],
    })


def answer_json(response):
    """The model's JSON answer, or None when a safety filter blocked it. Malformed output raises."""
    if response.get("promptFeedback", {}).get("blockReason"):
        return None
    candidates = response.get("candidates") or []
    if candidates and candidates[0].get("finishReason") in BLOCKED_FINISH_REASONS:
        return None
    parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
    text = "".join(part.get("text", "") for part in parts if not part.get("thought"))
    try:
        return json.loads(text)
    except ValueError:
        raise ProxyError(502, "upstream returned no valid answer")


def parse_gemini_response(response, labels, model):
    """Return the proxy answer. Safety blocks become 'unknown'; malformed output is an error."""
    answer = answer_json(response)
    if answer is None:
        return {"label": "unknown", "confidence": 0.0, "model": model}
    try:
        label, confidence = answer["label"], float(answer["confidence"])
    except (ValueError, KeyError, TypeError):
        raise ProxyError(502, "upstream returned no valid label")
    if label not in labels or not 0 <= confidence <= 1:
        raise ProxyError(502, "upstream returned no valid label")
    return {"label": label, "confidence": confidence, "model": response.get("modelVersion", model)}


def parse_checkout_response(response, model):
    """Return the proxy answer, the box as 0-1 fractions. Safety blocks count as not found;
    malformed output (a found machine without a sensible box, say) is an error."""
    answer = answer_json(response)
    if answer is None:
        return {"found": False, "box": None, "confidence": 0.0, "model": model}
    invalid = ProxyError(502, "upstream returned no valid self-checkout answer")
    try:
        found, confidence = answer["found"], float(answer["confidence"])
    except (ValueError, KeyError, TypeError):
        raise invalid
    if not isinstance(found, bool) or not 0 <= confidence <= 1:
        raise invalid
    model = response.get("modelVersion", model)
    if not found:
        return {"found": False, "box": None, "confidence": confidence, "model": model}
    box = answer.get("box_2d")
    if (not isinstance(box, list) or len(box) != 4
            or not all(isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 1000 for v in box)
            or box[0] >= box[2] or box[1] >= box[3]):
        raise invalid
    return {"found": True, "box": [v / 1000 for v in box], "confidence": confidence, "model": model}


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


def find_checkout(body, config, send=call_gemini):
    image = parse_checkout_request(body)
    if config.get("mock_label"):
        # Connection tests: a machine in the middle of every frame.
        return {"found": True, "box": [0.25, 0.25, 0.75, 0.75], "confidence": 0.95, "model": "mock"}
    request = build_checkout_request(image)
    return parse_checkout_response(send(request, config["api_key"], config["model"]), config["model"])


ROUTES = {"/v1/produce-label": label_image, "/v1/self-checkout": find_checkout}


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
            route = ROUTES.get(self.path)
            if route is None:
                return self._reply(404, {"error": "not found"})
            token = config.get("token")
            if token and not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                return self._reply(401, {"error": "unauthorized"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY_BYTES:
                return self._reply(413, {"error": "body too large or empty"})
            try:
                self._reply(200, route(self.rfile.read(length), config, send))
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
    print(f"Cloud assist proxy on http://{host}:{port}: /v1/produce-label and /v1/self-checkout ({mode})")
    ThreadingHTTPServer((host, port), make_handler(config)).serve_forever()


if __name__ == "__main__":
    main()
