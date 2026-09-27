# Cloud assist proxy (Gemini)

This small server sits between the iPhone and Google's Gemini API. The phone sends one downscaled JPEG crop for produce. Apple Vision is used first. Gemini is asked only after Apple Vision has worked alone for 5 seconds from when the shopper reaches the item's spot (detection turns on) without asking, at most 2 calls per item; after a call that did not lead to a question, Apple Vision gets another 5 seconds. A failed or late call leaves Apple Vision's result. The server holds the Google AI Studio API key, asks Gemini for exactly one broad label from the MVP taxonomy (`onion`, `apple`, …, or `unknown`), and returns `{"label", "confidence", "model"}`. It uses only the Python standard library, so there is nothing to install.

## Get a key

1. Go to [Google AI Studio](https://aistudio.google.com/apikey) and sign in with a Google account.
2. Click **Create API key** and copy it.
3. Keep it on the Mac only, in the `GEMINI_API_KEY` environment variable. Never paste it into the iPhone app.

The free tier is enough for demo testing. Check Google's current terms before sending store photos: on the free tier, submitted content may be used to improve Google's products. Enable billing on the key's project if that isn't acceptable.

## Run

```bash
cd ItemRecognition/CloudProxy

# Connection test without an API key: always answers "onion".
CLOUD_PROXY_MOCK_LABEL=onion PROXY_TOKEN=dev-token python3 server.py

# Real cloud labels from Gemini.
GEMINI_API_KEY=<your AI Studio key> PROXY_TOKEN=dev-token python3 server.py
# Optional: GEMINI_MODEL=gemini-3.8-flash (default gemini-3.1-flash-lite)
```

In the demo app's item picker, enter `http://<your-mac-name>.local:8787/v1/produce-label` and the same `PROXY_TOKEN`, then start a produce scan. The camera shows the model name from `/healthz` (for example `Gemini · gemini-3.1-flash-lite`) and updates it from the first answer. The phone and the Mac must be on the same network. iOS asks once for local-network permission. `PROXY_TOKEN` is a password you make up for your own proxy; it is not the Gemini key.

```bash
python3 -m unittest test_server    # proxy tests, Gemini mocked
curl http://localhost:8787/healthz
# {"ok": true, "mock": false, "model": "gemini-3.1-flash-lite"}
```

## Behavior and limits

- Packaged products never reach the cloud; they use on-device OCR.
- Each request is a single `generateContent` call: the prompt plus the JPEG as `inline_data`. `responseMimeType: application/json` and a `responseJsonSchema` restrict `label` to the list the app sent.
- Safety blocks return `unknown`. Other upstream errors pass back Google's message (for example, an invalid key or model name), and the app falls back to its on-device result.
- Images are not written to disk or logged.
- Cloud confidence is self-reported by the model, not calibrated. A Gemini answer naming the target at or above the produce score threshold asks the shopper at once (their Yes/No is the final check); an answer is used for its own frame only and never reused. The app waits up to 4 seconds per call.
- `CloudAssistPolicy.maximumRequestsPerItem` (default 2) caps Gemini calls per item scan, and `appleVisionSeconds` (default 5) sets Apple Vision's solo time; `maximumRequests` (200) is a backstop. After the cap, or on any timeout or error, the app uses its on-device result. The demo's **Test connection** button checks `/healthz` (no Gemini call), and the scan screen shows calls used, time until the next call, and the last answer.
- This is a development proxy: plain HTTP on the local network, with one shared token. Put it behind HTTPS with per-user auth and rate limits before any real deployment.
