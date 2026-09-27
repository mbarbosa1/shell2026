import Foundation

/// Turns the cart sensor's distance readings (one every 100 ms) into "obstacle ahead" on or off.
///
/// It uses two thresholds so the watch doesn't flicker when someone stands right at the edge:
/// - **On** after `closeReadingsNeeded` readings in a row closer than `onBelowCm`.
/// - **Off** only after `clearReadingsNeeded` readings in a row farther than `offAboveCm`, or no echo.
///
/// Readings between the two thresholds keep whatever state it's in. Needing a few readings
/// in a row also ignores the odd bad reading ultrasonic sensors give.
struct ObstacleDetector {
    /// How close counts as "in front", measured from the sensor on the cart's front.
    /// 100 cm gives about a second to stop at a normal walking pace (~1 m/s). Lower it if the
    /// alarm goes off too much in crowded aisles; keep `offAboveCm` about 30 cm above it.
    var onBelowCm = 100
    var offAboveCm = 130
    var closeReadingsNeeded = 2  // 0.2 s
    var clearReadingsNeeded = 3  // 0.3 s

    private(set) var isObstacleAhead = false
    /// How many readings in a row have pointed the other way from the current state.
    private var streak = 0

    /// Feeds one reading in cm (0 means no echo: nothing within about 4 m).
    /// Returns true when `isObstacleAhead` changed.
    mutating func update(distanceCm: Int) -> Bool {
        let isClose = distanceCm > 0 && distanceCm < onBelowCm
        let isClear = distanceCm == 0 || distanceCm > offAboveCm

        let pointsToOtherState = isObstacleAhead ? isClear : isClose
        streak = pointsToOtherState ? streak + 1 : 0

        let needed = isObstacleAhead ? clearReadingsNeeded : closeReadingsNeeded
        guard streak >= needed else { return false }
        isObstacleAhead.toggle()
        streak = 0
        return true
    }

    /// Back to "clear", e.g. when the cart disconnects.
    mutating func reset() {
        isObstacleAhead = false
        streak = 0
    }
}
