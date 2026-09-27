import Vision

/// The Vision request revisions this package runs, pinned so an iOS update cannot silently change
/// what the models return between trials. Every request sets its revision from here, and
/// `summary` goes into trial records so results are only compared when they match.
///
/// Each is the newest revision available on iOS 17, the package's minimum.
public enum VisionRevisions {
    /// `VNRecognizeTextRequest` (OCR).
    public static let text = VNRecognizeTextRequestRevision3
    /// `VNGenerateForegroundInstanceMaskRequest` (locating objects).
    public static let foregroundMask = VNGenerateForegroundInstanceMaskRequestRevision1
    /// `VNTrackObjectRequest` (following one object between segmentations).
    public static let tracking = VNTrackObjectRequestRevision2
    /// `VNDetectRectanglesRequest` (package outline).
    public static let rectangles = VNDetectRectanglesRequestRevision1
    /// `VNDetectTextRectanglesRequest` (where the label's text is).
    public static let textRectangles = VNDetectTextRectanglesRequestRevision1
    /// `VNClassifyImageRequest` (Apple Vision produce classes).
    public static let classify = VNClassifyImageRequestRevision2

    /// "text=3 mask=1 track=2 rect=1 textRect=1 classify=2"
    public static var summary: String {
        "text=\(text) mask=\(foregroundMask) track=\(tracking) rect=\(rectangles) "
            + "textRect=\(textRectangles) classify=\(classify)"
    }
}
