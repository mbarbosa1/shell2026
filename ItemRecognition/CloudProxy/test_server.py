import base64
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import server

JPEG = b"\xff\xd8" + b"\x00" * 32
LABELS = ["apple", "onion", "unknown"]


def body(image=JPEG, labels=LABELS):
    return json.dumps({"image_base64": base64.b64encode(image).decode(), "labels": labels}).encode()


def gemini_reply(text, model="gemini-test-001", finish="STOP"):
    return {"modelVersion": model, "candidates": [{"finishReason": finish, "content": {"role": "model", "parts": [
        {"text": "thinking about the image", "thought": True},
        {"text": text},
    ]}}]}


class ProxyTests(unittest.TestCase):
    config = {"api_key": "gemini-key", "model": "gemini-test", "token": "", "mock_label": ""}

    def test_request_is_constrained_to_allowed_labels(self):
        sent = {}

        def send(request, key, model):
            sent.update(request=request, key=key, model=model)
            return gemini_reply('{"label": "onion", "confidence": 0.91}')

        result = server.label_image(body(), self.config, send)
        self.assertEqual(result, {"label": "onion", "confidence": 0.91, "model": "gemini-test-001"})
        self.assertEqual((sent["key"], sent["model"]), ("gemini-key", "gemini-test"))
        config = sent["request"]["generationConfig"]
        self.assertEqual(config["responseMimeType"], "application/json")
        self.assertEqual(config["responseJsonSchema"]["properties"]["label"]["enum"], LABELS)
        image = sent["request"]["contents"][0]["parts"][1]["inline_data"]
        self.assertEqual(image["mime_type"], "image/jpeg")
        self.assertEqual(base64.b64decode(image["data"]), JPEG)

    def test_invalid_requests_are_rejected(self):
        for bad in [body(image=b"GIF89a"), body(labels=["onion"]), body(labels=["Yellow Onion", "unknown"]),
                    b"not json", body(image=JPEG + b"\x00" * server.MAX_IMAGE_BYTES)]:
            with self.assertRaises(server.ProxyError) as caught:
                server.label_image(bad, self.config, lambda *_: self.fail("upstream called"))
            self.assertEqual(caught.exception.status, 400)

    def test_safety_blocks_become_unknown_and_bad_output_is_an_error(self):
        blocked_prompt = {"promptFeedback": {"blockReason": "SAFETY"}}
        blocked_answer = gemini_reply("", finish="IMAGE_SAFETY")
        for response in [blocked_prompt, blocked_answer]:
            self.assertEqual(server.parse_gemini_response(response, LABELS, "m")["label"], "unknown")
        for text in ['{"label": "yellow_onion", "confidence": 0.9}', '{"label": "onion", "confidence": 3}', "oops"]:
            with self.assertRaises(server.ProxyError):
                server.parse_gemini_response(gemini_reply(text), LABELS, "m")
        with self.assertRaises(server.ProxyError):
            server.parse_gemini_response({"candidates": []}, LABELS, "m")

    def test_mock_mode_skips_gemini(self):
        config = dict(self.config, api_key="", mock_label="onion")
        result = server.label_image(body(), config, lambda *_: self.fail("upstream called"))
        self.assertEqual(result["label"], "onion")
        self.assertEqual(result["model"], "mock")

    def test_http_round_trip_requires_token(self):
        config = dict(self.config, token="secret")
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(
            config, lambda *_: gemini_reply('{"label": "apple", "confidence": 0.8}')))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        url = f"http://127.0.0.1:{httpd.server_address[1]}/v1/produce-label"

        def post(token):
            request = urllib.request.Request(url, data=body(), method="POST",
                headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
            return urllib.request.urlopen(request, timeout=5)

        with self.assertRaises(urllib.error.HTTPError) as caught:
            post("wrong")
        self.assertEqual(caught.exception.code, 401)
        caught.exception.close()
        with post("secret") as response:
            self.assertEqual(json.load(response)["label"], "apple")


if __name__ == "__main__":
    unittest.main()
