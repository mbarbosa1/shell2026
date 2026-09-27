# Voice agent: Mira

Mira is an [ElevenLabs Conversational AI](https://elevenlabs.io/conversational-ai) agent. The app streams the mic to her, plays her voice, and runs her **client tools** on the phone, so the list is edited in the local database with no backend.

Source: `UI/ShellApp/ShellApp/VoiceAgent.swift`, `VoiceConfig.swift`, `Narrator.swift`.

## Stack

| Piece | Version |
|---|---|
| [ElevenLabs Swift SDK](https://github.com/elevenlabs/elevenlabs-swift-sdk) (Swift Package Manager) | 3.3.1 |
| LiveKit client + WebRTC (pulled in by the SDK) | 2.17.0 |
| AVFoundation | Mic permission, `Narrator` |

## Setup

1. Create an agent in the ElevenLabs dashboard. Write its system prompt: a friendly grocery assistant named Mira that edits the list with the tools below. (The prompt isn't stored in this repo.)
2. Add each tool under **Agent → Tools → Add tool → Client**. Use the exact names and parameters, and turn on **Wait for response**.
3. Copy the agent ID into the scheme: **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**:
   - `ELEVENLABS_AGENT_ID`: always.
   - `ELEVENLABS_API_KEY`: only if the agent has authentication on. Used in Debug builds only.
4. Run from Xcode (⌘R). Environment variables aren't set when the app is opened from the home screen.

> Don't ship the API key in the app. For a release build, have a backend fetch the conversation token from `https://api.elevenlabs.io/v1/convai/conversation/token`.

## Client tools

Parameters are strings unless noted. The item name can be `name` or `item_name`.

| Tool (alias) | Parameters | Does |
|---|---|---|
| `get_grocery_list` (`get_list`) | `number` (int, optional) | Reads a list. The open one by default |
| `add_grocery_item` (`add_item`) | `name`, optional `brand`, `label`, `size`, `quantity` (int), `aisle` (int), `block` | Adds an item and matches it to the catalog |
| `update_grocery_item` (`update_item`) | `name`, any of `quantity`, `brand`, `label`, `size`, `aisle`, `block`, `in_cart` (bool) | Edits an item. `in_cart: true` checks it off |
| `set_item_location` | `name`, `aisle` (int), `block` | Sets where it is in the store |
| `remove_grocery_item` (`remove_item`) | `name` | Removes an item |
| `check_off_item` | `name` | Puts it in the cart. Also means **yes** to the camera's "Is this …?" |
| `cancel_current_operation` | none | **No** to "Is this …?" (keeps looking) |
| `add_usuals`, `get_most_common_items`, `get_last_trip` | none | Uses past lists |
| `get_list_history` | `number` (int, optional) | Change log of a list |
| `finish_list` (`finished_list`) | `store` (optional) | Closes the list. Only runs if the user clearly said they're done |
| `open_camera` (`open_camera_or_close`), `close_camera` | none | Starts or ends shopping |
| `analyze_current_frame` | none | Reports what the scanner sees right now |
| `next_page`, `previous_page`, `finish_onboarding` | none | Moves through onboarding |

To add a tool: add a `case` to `run(_:parameters:)` in `VoiceAgent.swift` **and** add it in the dashboard with the same name.

## Behavior to know

- Mira connects only when the user taps the listen button, never at launch.
- **Stop listening** ends the conversation, so she stops talking at once (and stops billing).
- While shopping, her mic is off during walking and turns on at each stop, after the arrival message is read. The camera screen's mic button overrides this until the next stop.
- She's turned off while VoiceOver is on.
- Onboarding: `Narrator` reads the pages and asks for the mic, then starts Mira. Optional clips in Mira's voice: `onboarding_0.mp3`, `onboarding_1.mp3`, …, `onboarding_ask_mic.mp3`, `onboarding_mic_on.mp3`, `onboarding_mic_off.mp3`. Add them to the app target.

## Debugging

Debug builds print every tool call, its result, and a database snapshot to the Xcode console, prefixed with 🛒.
