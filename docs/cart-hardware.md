# 3D model and cart hardware

A mount on the shopping cart that holds the iPhone in a servo-driven clamp and senses obstacles ahead. An ESP32 runs it and talks to the phone over Bluetooth LE.

Source: `firmware/` (PlatformIO), `UI/ShellApp/ShellApp/CartBluetooth.swift`, `ArmController.swift`, `ObstacleDetector.swift`, `PickupGuide.swift`.

## Parts

| Part | Notes |
|---|---|
| ESP32-S3-DevKitC-1 | Runs the firmware |
| 3× MG90S servos | **pan** turns the phone left/right; **tilt1** and **tilt2** hold both sides of the phone clamp and tilt it together |
| Ultrasonic sensor, 3.3 V (HC-SR04P or RCWL-1601) | Faces forward on the cart |
| Printed arm and clamp | Holds the phone upright (portrait); the camera faces the shelf |
| 5 V supply for the servos | Don't power 3 servos from the ESP32's 3.3 V pin |

## Wiring

| Signal | GPIO |
|---|---|
| Servo pan | 4 |
| Servo tilt1 | 5 |
| Servo tilt2 | 6 |
| Sensor TRIG | 7 |
| Sensor ECHO | 15 |

> A classic 5 V HC-SR04 outputs 5 V on ECHO, which can damage the ESP32-S3. Use a 3.3 V sensor, or put a voltage divider (1 kΩ + 2 kΩ) on ECHO.

## Flash the firmware

1. Install [VS Code](https://code.visualstudio.com/) and the **PlatformIO IDE** extension (recommended by `firmware/.vscode/extensions.json`).
2. Open the `firmware/` folder. PlatformIO installs the `espressif32` platform and `madhephaestus/ESP32Servo` on its own.
3. Plug in the board and click **Upload** (env `s3`). Then open the **Serial Monitor** (115200 baud). You should see `CartArm ready, waiting for phone...`.

## Test without the phone (Serial Monitor)

| Type | Does |
|---|---|
| `90,90,90` | Moves pan, tilt1, tilt2 to those angles (clamped to 20–160°, smoothed) |
| `d` | Turns the distance printout on or off |

**Always move tilt1 and tilt2 together.** Moving only one twists the clamp. Use this test to decide `ArmController.tiltMirrored`: whichever setting tilts the clamp without twisting it.

## Bluetooth protocol

The ESP32 advertises as **CartArm**. The iPhone app finds and connects to it on its own, and reconnects if it drops.

| Characteristic | UUID | Format |
|---|---|---|
| Service | `7d2a0001-4b3c-4f2a-9a61-3c5e8f1b2a10` | |
| COMMAND (write) | `7d2a0002-…` | 3 raw bytes `pan, tilt1, tilt2`, or text `"60,90,120"` |
| DISTANCE (notify) | `7d2a0003-…` | 2 bytes, little-endian cm, every 100 ms. `0` = nothing within ~4 m. Readings under 30 cm are dropped |

The UUIDs must match in `firmware/src/main.cpp` and `CartBluetooth.swift`. You can also test with the LightBlue or nRF Connect apps.

## Calibrate on the real arm

In `ArmController.swift`: `home`, `panFacingLeft`/`panFacingRight`, `panRange`, `tiltRange`, `tiltMirrored`, and `panDirection`/`tiltDirection` (flip to `-1` if centering turns away from the product). In the firmware: `MIN_ANGLE`/`MAX_ANGLE` (so the arm can't hit its frame) and `MAX_STEP` (speed).

## Status

- **Working:** Bluetooth link, distance → obstacle alarm on the watch, servo control.
- **Not connected yet:** the arm sweep and centering in `PickupGuide` don't get product sightings from recognition. Try it with the Debug **Test hand guide** button on the camera screen.
- The 3D model files (STL/CAD) for the arm and clamp aren't in the repo yet. Add them to `firmware/` so others can print it.
