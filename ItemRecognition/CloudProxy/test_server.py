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


def checkout_body(image=JPEG):
    return json.dumps({"image_base64": base64.b64encode(image).decode()}).encode()


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

    def test_checkout_request_asks_for_a_box_and_scales_it(self):
        sent = {}

        def send(request, key, model):
            sent.update(request=request)
            return gemini_reply('{"found": true, "box_2d": [100, 200, 900, 600], "confidence": 0.87}')

        result = server.find_checkout(checkout_body(), self.config, send)
        self.assertEqual(result, {"found": True, "box": [0.1, 0.2, 0.9, 0.6], "confidence": 0.87,
                                  "model": "gemini-test-001"})
        schema = sent["request"]["generationConfig"]["responseJsonSchema"]
        self.assertEqual(set(schema["properties"]), {"found", "box_2d", "confidence"})
        self.assertIn("self-checkout", sent["request"]["contents"][0]["parts"][0]["text"])
        image = sent["request"]["contents"][0]["parts"][1]["inline_data"]
        self.assertEqual(base64.b64decode(image["data"]), JPEG)

    def test_checkout_not_found_has_no_box(self):
        result = server.find_checkout(checkout_body(), self.config,
                                      lambda *_: gemini_reply('{"found": false, "confidence": 0.9}'))
        self.assertEqual((result["found"], result["box"]), (False, None))

    def test_checkout_bad_answers_are_errors(self):
        for text in ['{"found": true, "confidence": 0.9}',
                     '{"found": true, "box_2d": [100, 200, 900], "confidence": 0.9}',
                     '{"found": true, "box_2d": [100, 200, 1900, 600], "confidence": 0.9}',
                     '{"found": true, "box_2d": [900, 200, 100, 600], "confidence": 0.9}',
                     '{"found": "yes", "box_2d": [100, 200, 900, 600], "confidence": 0.9}',
                     '{"found": true, "box_2d": [100, 200, 900, 600], "confidence": 2}',
                     "oops"]:
            with self.assertRaises(server.ProxyError) as caught:
                server.parse_checkout_response(gemini_reply(text), "m")
            self.assertEqual(caught.exception.status, 502)

    def test_checkout_safety_block_is_not_found(self):
        result = server.parse_checkout_response({"promptFeedback": {"blockReason": "SAFETY"}}, "m")
        self.assertEqual((result["found"], result["box"]), (False, None))

    def test_checkout_rejects_non_jpeg_and_mock_skips_gemini(self):
        with self.assertRaises(server.ProxyError) as caught:
            server.find_checkout(checkout_body(image=b"GIF89a"), self.config, lambda *_: self.fail("upstream called"))
        self.assertEqual(caught.exception.status, 400)
        config = dict(self.config, api_key="", mock_label="onion")
        result = server.find_checkout(checkout_body(), config, lambda *_: self.fail("upstream called"))
        self.assertEqual((result["found"], result["model"]), (True, "mock"))

    def test_checkout_http_round_trip(self):
        config = dict(self.config, token="secret")
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(
            config, lambda *_: gemini_reply('{"found": true, "box_2d": [0, 0, 500, 500], "confidence": 0.7}')))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        request = urllib.request.Request(f"http://127.0.0.1:{httpd.server_address[1]}/v1/self-checkout",
                                         data=checkout_body(), method="POST",
                                         headers={"Content-Type": "application/json", "Authorization": "Bearer secret"})
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(json.load(response)["box"], [0.0, 0.0, 0.5, 0.5])

    def test_healthz_reports_the_configured_model(self):
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.config, lambda *_: {}))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        url = f"http://127.0.0.1:{httpd.server_address[1]}/healthz"
        with urllib.request.urlopen(url, timeout=5) as response:
            body = json.load(response)
        self.assertEqual(body, {"ok": True, "mock": False, "model": "gemini-test"})


if __name__ == "__main__":
    unittest.main()
