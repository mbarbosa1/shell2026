# PersonDistance — implementation plan for review

Status: planning only, September 27, 2026. No implementation or device testing has been performed. The user requested review before code is written.

## Interim display readout (September 27, 2026, user direction)

All phone-to-product distance code lives in this folder; UI code only displays its results. One interim piece exists ahead of the plan below: `Package.swift` with the `PersonDistanceIOS` target and `Sources/PersonDistanceIOS/ProductDepthEstimator.swift`. ShellApp (not the Demo) links it and shows the reading on its camera screen, beside the item being looked for ("Looking for Oat milk · 1.2 m"), while `ItemScanner` searches at a stop. It is display-only: nothing is spoken, sent to the watch, or decided from it.

It follows two rules of this plan: it measures one product only (the object recognition matched, or the object region when exactly one object is in view, never a union of several), and it uses LiDAR scene depth when available (median of medium/high-confidence samples in the middle half of the box, converted from camera-plane depth to straight-line range with the camera intrinsics). Without scene depth (no LiDAR, or no depth on that frame) it falls back to an ARKit raycast against estimated surfaces, which this plan leaves out of scope.

Not yet met: it measures before automatic confirmation; scene depth is enabled when the camera starts rather than after confirmation; it reads ARKit's latest frame instead of the frame recognition checked, so the box can be a fraction of a second old; there is no `PersonDistanceCore`, target tracking, validity policy, watch guidance, or tests. Verified only by unsigned iOS device and simulator builds of ShellApp; no device measurement yet.

## Confirmed requirements

- Measure only after automatic product identification is confirmed; shopper acceptance is not the trigger.
- Use phone-to-product distance only.
- Deliver guidance through Apple Watch vibrations only; no spoken guidance.
- Do not require the shopper to hold the phone in the opposite hand or keep the grasping hand visible.
- Agreed endpoint: guide toward the product; the shopper completes the grasp by touch.
- Phone: iPhone 18 Pro. Watch candidates: Apple Watch Series 5 or the latest model. Installed OS versions and the watch to use first remain unknown.
- Choose the near-phone stopping distance during the first supervised calibration.

## Agreed scope and spatial meaning

These sensing constraints support product localization relative to the camera and phone-to-product distance feedback. They do not provide the position of an unseen hand. Even perfect phone distance cannot tell whether a hand is above, below, behind, or beside the product, whether its path is clear, or whether fingers have closed around it.

The user resolved this distinction by choosing guidance toward the product with manual grasp by touch. The plan does not assume that watch motion sensors or radio ranging supply product-relative fingertip position.

Provide product-relative phone alignment/proximity cues, followed by a distinct near-product stop cue. The shopper finishes the grasp by touch. Explicit collection confirmation is the proposed way to mark the task complete; its input method remains to be settled. No command may claim “move your hand left” or “close your fingers now” from phone distance alone.

Remaining implementation-review decisions: exact watch/OS and active-app behavior; automatic-confirmation reliability policy; vibration vocabulary/training; accessible stop and collection controls. Automatic confirmation and supervised distance calibration are now approved requirements. No further shopper confirmation is required to start measuring.

## Hardware verification

The user confirmed iPhone 18 Pro. Apple lists a LiDAR Scanner in the [iPhone 18 Pro/Pro Max specifications](https://www.apple.com/iphone-18-pro/specs/). Use the LiDAR scene-depth design and still check `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` at runtime. [ARKit scene depth](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth) requires LiDAR. Non-LiDAR support is outside this first implementation.

The latest standard watch listed by Apple at review time is [Series 12](https://www.apple.com/watch/). Series 5 is absent from the [watchOS 27 compatibility list](https://www.apple.com/os/watchos/); do not set a deployment target that excludes it while claiming support. Before choosing a shared deployment baseline, verify the actual Series 5 software, pairing with the specific iPhone/OS, current Xcode installation/deployment support, and signed installation. Latest-watch support and Series 5 support are separate device test cases. Existing haptic and connectivity APIs are candidate building blocks, not proof that this exact device pair has been validated.

## Existing code path and integration gaps

The running recognition app is `ItemRecognition/Demo/ItemRecognitionDemo.xcodeproj`; the two ShellApp projects are not the initial integration target.

| Existing file | Current behavior | Planned change |
|---|---|---|
| `ItemRecognition/Demo/Sources/ScanModel.swift` | `confirmInsight()` requests shopper acceptance and immediately stops capture. | Add the automatic-confirmation transition into distance acquisition, retaining the camera. |
| `ItemRecognition/Demo/Sources/DemoCameraCapture.swift` | Owns AVCaptureSession and discards the returned shopper-acceptance observation. | Deliver a distinct automatic target handoff and replace capture with one ARKit source in the integrated demo. |
| `ItemRecognition/Sources/ItemRecognition/Extraction/RecognitionCoordinator.swift` | Machine `.confirmed` settles into an awaiting-shopper state; `acceptInsight()` returns ItemObservation once and stops recognition. | Add an explicit automatic-confirmation handoff contract for this mode, including identity and spatial evidence; preserve shopper-acceptance meaning elsewhere. |
| `ItemRecognition/Sources/ItemRecognition/Catalog/ItemRecognitionResult.swift` | ItemObservation contains identity and timestamp but no target rectangle. | Keep identity separate from a new spatial handoff record. |
| `ItemRecognition/Demo/Sources/CameraDemoView.swift` | Displays AVCapture preview and recognition controls. | Use AR preview and provide guidance lifecycle controls. |

A machine result named `.confirmed` currently asks the shopper for acceptance; it is not their final acceptance. The user now requires that automatic confirmation trigger measurement in PersonDistance mode. Add an explicit automatic handoff rather than pretending the shopper called `acceptInsight()`. Preserve the accepted-by-shopper semantics for other consumers and baseline reporting. One event per target/session must transition the pipeline; repeated settled updates must not restart guidance.

The current OCR policy can ask after one qualifying frame because shopper acceptance was its final check. Do not assume that policy is already validated for automatic movement guidance. Review temporal consistency, target-versus-neighbor margin, and fresh physical-target association before enabling automatic guidance; calibrate that policy using device trials. The first test uses one exact packaged product. A `.category` produce result does not confirm an exact SKU or one physical item and must not automatically start exact-product guidance. Category-level shopping targets would need a separate explicit contract.

`RecognitionUpdate.focusedObject` covers certain multi-object OCR results only. `assessment.objectRegion` may be a union of objects. Define one explicit physical target with its source-frame coordinates. Do not use a text crop, full frame, or produce-bin union as an individual product surface. A produce category match needs an additional individual-target selection step.

## Planned files under PersonDistance

Only this README exists. Proposed implementation files:

| Location | Responsibility |
|---|---|
| `Package.swift` | Portable contracts plus a separate iOS-only ARKit target. |
| `Sources/PersonDistanceCore/ConfirmedTarget.swift` | Item ID, recognition session, match level, frame timestamp, rectangle, resolution, orientation. |
| `Sources/PersonDistanceCore/DistanceSample.swift` | Camera-to-product range, selected surface, age, quality, and validity. |
| `Sources/PersonDistanceCore/SpatialValidityPolicy.swift` | Target association, freshness, confidence, and abstention rules. |
| `Sources/PersonDistanceCore/GuidanceCoordinator.swift` | Confirmation gate, state transitions, cancellation, near threshold, and hysteresis. |
| `Sources/PersonDistanceCore/GuidanceMessage.swift` | Shared iPhone/watch message schema. |
| `Sources/PersonDistanceIOS/ARCameraSource.swift` | Own the ARSession and timestamped frames. |
| `Sources/PersonDistanceIOS/ConfirmedObjectTracker.swift` | Maintain the same physical target across frames. |
| `Sources/PersonDistanceIOS/ProductDepthEstimator.swift` | Map the selected surface to scene depth and calculate range. |
| `Sources/PersonDistanceIOS/WatchGuidanceSender.swift` | Live connectivity, acknowledgments, and stale-message control. |
| `WatchApp/` | Receiver, vibration vocabulary, stop/collection controls, and training interaction. |
| `Tests/` | Confirmation, geometry, target identity, state, and messaging checks. |

No hand-tracking or automatic grasp planner is included under the phone-only constraint. A companion watchOS app target, bundle association, signing, and deployment configuration must be added to the demo project. A package folder alone does not create an installable watch app. The shared target must not import ARKit or the iOS recognition package.

## Step-by-step implementation and first test

1. **Finalize the remaining interaction choices.** Use the agreed iPhone 18 Pro, automatic recognition confirmation, supervised near-phone calibration, and manual-grasp endpoint. Identify the watch/OS, automatic-confirmation reliability policy, and collection-confirmation input. Define phone proximity independently of hand reach. No claim of grasp detection follows from small phone range.

2. **Define the state model.** Recognizing → automatically confirmed → acquiring target → measuring → valid proximity feedback → near-phone threshold → manual grasp → awaiting explicit collection confirmation → completed. There is no shopper-verdict wait before measurement. Include paused, cancelled, and unsupported states. Every target/session change invalidates old frames, samples, and watch messages.

3. **Use one ARKit camera owner.** Start world tracking for RGB recognition/preview. Keep scene-depth semantics disabled before automatic confirmation and also gate all product-range calculation. Feed ARFrame.capturedImage to RecognitionImage with the actual orientation. The old AVCapture path physically rotates buffers and uses `.up`; do not copy that assumption. Validate focus/blur handling, format, buffer ownership, camera permission, interruptions, and backpressure. Do not run a competing AVCaptureSession.

4. **Make the automatic handoff atomic.** Store the confirmed result's identity, match level, selected physical region, and session/frame identity in one handoff record. Deliver it once only after the agreed automatic-confirmation policy passes. Reject category-only, wrong-target, or obsolete results for an exact-product request. End or suspend recognition through an explicit automatic handoff, without recording fictitious shopper acceptance. Separate the recognition trial's machine-confirmed outcome from collection and camera stopping. Stop submitting recognition work to a stopped coordinator.

5. **Acquire the confirmed object in a current frame.** Maintain RGB continuity through recognition and depth startup. Use [Vision object tracking](https://developer.apple.com/documentation/vision/vntrackobjectrequest) plus identity/continuity checks. If the selected item was lost or ambiguously replaced by a neighbor, pause and repeat automatic confirmation. Do not apply an old recognition rectangle to new depth data.

6. **Enable and validate product depth.** Check support, then enable `.sceneDepth` without intentionally resetting tracking. Map current target coordinates into the same ARFrame's depth/confidence buffers. Handle image orientation, depth resolution, and preview cropping separately. Use interior samples belonging to the selected visible product surface; reject low-confidence, nonfinite, edge, background, and occluder samples. Refrain from calculating a usable range if association is ambiguous.

   Unproject using correctly scaled camera intrinsics and compute Euclidean camera-to-surface range. Raw depth is distance from the camera plane and differs from off-axis range. Use robust sample aggregation and limited temporal smoothing; clear history after target changes or loss. Apple's [ARDepthData documentation](https://developer.apple.com/documentation/arkit/ardepthdata) defines depth/confidence maps. Spatial validity uses association, depth confidence, spread, freshness, and tracking stability. Recognition score is not depth accuracy, and raw confidence scores from different APIs are not interchangeable probabilities.

7. **Derive only supported feedback.** Range supplies proximity. The target's image position additionally supplies camera-relative alignment; neither establishes a hand/body-relative direction. Do not require a particular hand posture, but the rear camera must still see the product. A configurable near-phone threshold must be named as such, not “within hand reach.” Use hysteresis and expire measurements. Occlusion, tracking loss, or invalid depth pauses feedback. Distance to a product does not establish a clear walking route.

8. **Connect the watch.** Activate WCSession on both devices and check installation, pairing, activation, and reachability. Send session ID, sequence, target ID, cue, sample age, and expiry information. Use one replaceable latest update rather than a camera-rate backlog. Validate freshness with acknowledgments and a measured latency/clock-handling protocol; independent monotonic clocks cannot be compared directly. Discard duplicates and previous sessions. Do not replay live guidance via deferred background transfers. See Apple's [sendMessage documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)).

9. **Develop vibration-only feedback.** Provide no spoken guidance. Prototype distinguishable proximity and pause/completion cues with the system haptics and cadence limits; do not promise arbitrary motor strength. Faster pulses, if chosen, indicate decreasing phone range only. Stop and success retain their task meanings; success requires explicit collection confirmation. Any camera-alignment vocabulary needs learned, unambiguous meanings and user testing before it directs motion. Do not claim a single wrist actuator naturally communicates spatial direction. See [WKHapticType](https://developer.apple.com/documentation/watchkit/wkhaptictype).

   Verify the watch can remain active in the shopper's actual posture. Apple's [play(_:) documentation](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)) restricts background/inactive playback. Do not promise a stop vibration after communication or app activity is lost. Train bounded action per movement cue, followed by stopping and waiting; silence never means keep moving. Resume only with fresh valid state. Provide accessible stop and collection actions without introducing spoken guidance as a hidden dependency. Product identification is confirmed automatically.

10. **Run focused software checks.** Cover no estimates/cues before automatic confirmation; candidate/no-match/category-only results; duplicate machine-confirmed updates; wrong/stale session handoff; object switching; stale coordinates; portrait/landscape transforms; off-axis range; missing/mixed depth; hysteresis; interrupted capture; expired/reordered messages; disconnect/inactivity; and cancellation. Assert no shopper action is needed to start measurement and no false shopper-acceptance event is logged. Assert phone proximity never produces automatic hand-position, contact, or grasp claims. Build the recognition package, iOS demo, and watch targets for the agreed deployment versions.

11. **First physical bench test.** Use one opaque package in a well-lit uncluttered scene. Measure rear-camera-to-selected-surface reference distances, for example 1.0 m, 0.75 m, and 0.5 m. These are measurement points, not grasp or stop thresholds. First test randomized vibration recognition without motion, then automatically confirmed-target distance feedback. Record error, valid-sample coverage, latency, cue timing, and target identity. A proposed range target for review is at least 90% of valid samples within 10 cm at these points; it is not a validated accuracy claim or a grasp tolerance. Select and save the near-phone threshold with the shopper during supervised calibration, accounting for phone posture, measured error, cue delay, and room to stop; do not assume one phone distance establishes reachability in all postures.

   Verify zero product-range calculations before automatic confirmation and automatic startup afterward without an Accept tap. Vary distance and camera angle; occlude the product, introduce a similar neighbor, rotate the phone, lower the wrist, deactivate/disconnect the watch, and cancel. Freshness and pause behavior must remain correct. Test Series 5 and a current watch separately if both are supported. After cue comprehension and geometry checks pass, run a supervised complete trial: recognize automatically, approach an unobstructed product using the agreed cues, receive the calibrated near-phone stop cue, finish grasping by touch, and confirm collection. No hand tracking or automatic grasp detection is claimed.

## Runtime path

Demo app → ScanModel.start → ARCameraSource RGB frames → RecognitionCoordinator.submit → automatic exact-product confirmation → confirmed identity plus spatial target → fresh target acquisition → same-frame product depth → validity policy → phone proximity/alignment state → WatchConnectivity → active watch receiver → vibrations → calibrated phone-near stop cue → manual grasp by touch → collection confirmation.

The endpoint, automatic trigger, iPhone variant, vibration-only output, and supervised distance-calibration approach are agreed. Watch deployment, confirmation reliability settings, vibration vocabulary, and collection controls remain implementation-review details. Awaiting plan review; no code changes or tests performed.
