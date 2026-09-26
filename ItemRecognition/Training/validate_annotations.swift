// Validates a Create ML object-detection dataset against the MVP produce taxonomy.
//
//   swift ItemRecognition/Training/validate_annotations.swift ItemRecognition/Training/dataset
//
// Exit status 1 means the dataset must not be trained on. Warnings are reported
// but do not fail (for example, too few images for a first run).

import Foundation
import ImageIO

let splits = ["train", "validation", "test"]
let minimumTrainImagesPerClass = 100
let minimumSpecimensPerClass = 10
let here = URL(fileURLWithPath: #filePath).absoluteURL.deletingLastPathComponent()
let taxonomyURL = here.appendingPathComponent("../Sources/ItemRecognition/Resources/produce-taxonomy.json").standardized
let mappingsURL = here.appendingPathComponent("../../Scripts/RecognitionIntegration/Resources/visual-product-mappings.json").standardized

struct Coordinates: Decodable { let x, y, width, height: Double }
struct Box: Decodable { let label: String; let coordinates: Coordinates }
struct Entry: Decodable { let image: String; let annotations: [Box] }
struct Taxonomy: Decodable { let classes: [String: [String]] }
struct Mappings: Decodable {
    struct Product: Decodable { struct Visual: Decodable { let classIDs: [String] }; let visual: Visual }
    let products: [Product]
}
struct Capture { let split, specimen, session: String }

var errors: [String] = []
var warnings: [String] = []

guard CommandLine.arguments.count == 2 else {
    print("usage: swift validate_annotations.swift <dataset-directory>"); exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let labels = Set(try JSONDecoder().decode(Taxonomy.self, from: Data(contentsOf: taxonomyURL)).classes.keys)
let required = Set(try JSONDecoder().decode(Mappings.self, from: Data(contentsOf: mappingsURL)).products.flatMap(\.visual.classIDs))

// captures.csv: image,split,specimen_id,session_id[,any other columns]
var captures: [String: Capture] = [:]
do {
    let text = try String(contentsOf: root.appendingPathComponent("captures.csv"), encoding: .utf8)
    var rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
    let header = rows.isEmpty ? [] : rows.removeFirst()
    let column = { (name: String) -> Int? in header.firstIndex(of: name) }
    if let image = column("image"), let split = column("split"), let specimen = column("specimen_id"), let session = column("session_id") {
        for row in rows where row.count > max(image, split, specimen, session) {
            if captures[row[image]] != nil { errors.append("captures.csv lists \(row[image]) twice") }
            captures[row[image]] = Capture(split: row[split], specimen: row[specimen], session: row[session])
        }
    } else {
        errors.append("captures.csv header must include image,split,specimen_id,session_id")
    }
} catch {
    errors.append("Missing captures.csv: \(error.localizedDescription)")
}

func imageSize(_ url: URL, name: String) -> (Double, Double)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double else {
        errors.append("\(name): missing or unreadable image"); return nil
    }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    if orientation != 1 { errors.append("\(name): EXIF orientation \(orientation); re-export upright (orientation 1) before labeling") }
    return (width, height)
}

var instances: [String: [String: Int]] = [:]  // split -> label -> boxes
var images: [String: [String: Int]] = [:]     // split -> label -> images containing it
var specimens: [String: Set<String>] = [:]    // label -> specimen ids
var specimenSplit: [String: String] = [:]
var sessionSplit: [String: String] = [:]
var annotated = Set<String>()

for split in splits {
    let folder = root.appendingPathComponent(split)
    let entries: [Entry]
    do { entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: folder.appendingPathComponent("annotations.json"))) }
    catch { errors.append("\(split)/annotations.json: \(error)"); continue }
    for entry in entries {
        let name = "\(split)/\(entry.image)"
        if !annotated.insert(name).inserted { errors.append("\(name): listed twice") }
        guard let capture = captures[name] else { errors.append("\(name): not in captures.csv (use the split/file path)"); continue }
        if capture.split != split { errors.append("\(name): captures.csv says split \(capture.split)") }
        if capture.specimen.isEmpty || capture.session.isEmpty { errors.append("\(name): specimen_id and session_id are required") }
        for (key, value, kind) in [(capture.specimen, split, "specimen"), (capture.session, split, "session")] where !key.isEmpty {
            let seen = kind == "specimen" ? specimenSplit[key] : sessionSplit[key]
            if let seen, seen != value { errors.append("\(kind) \(key) appears in both \(seen) and \(value); split by \(kind), not by frame") }
            if kind == "specimen" { specimenSplit[key] = value } else { sessionSplit[key] = value }
        }
        if entry.annotations.isEmpty { errors.append("\(name): no boxes. Put no-produce images in negatives/, not in a Create ML split") }
        guard let (width, height) = imageSize(folder.appendingPathComponent(entry.image), name: name) else { continue }
        var labelsInImage = Set<String>()
        for box in entry.annotations {
            let c = box.coordinates
            if !labels.contains(box.label) {
                errors.append("\(name): label '\(box.label)' is not an MVP class. Use broad labels only (onion, not yellow_onion)")
            }
            if c.width <= 0 || c.height <= 0 { errors.append("\(name): \(box.label) box has no area") }
            // Create ML coordinates are the box centre, in pixels, origin top-left.
            if c.x - c.width / 2 < -1 || c.y - c.height / 2 < -1 || c.x + c.width / 2 > width + 1 || c.y + c.height / 2 > height + 1 {
                errors.append("\(name): \(box.label) box extends outside the \(Int(width))×\(Int(height)) image (x/y must be the centre)")
            }
            if min(c.width, c.height) < 16 { warnings.append("\(name): \(box.label) box under 16 px; too small to learn from") }
            instances[split, default: [:]][box.label, default: 0] += 1
            labelsInImage.insert(box.label)
            specimens[box.label, default: []].insert(capture.specimen)
        }
        for label in labelsInImage { images[split, default: [:]][label, default: 0] += 1 }
    }
}

let negatives = captures.filter { $0.value.split == "negative" }
for (name, _) in negatives where !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
    errors.append("\(name): negative image listed in captures.csv but missing")
}
for (name, capture) in captures where splits.contains(capture.split) && !annotated.contains(name) {
    errors.append("\(name): in captures.csv but not in \(capture.split)/annotations.json")
}

for label in required.sorted() {
    let train = images["train"]?[label] ?? 0
    if train < minimumTrainImagesPerClass { warnings.append("\(label): \(train) train images (target ≥ \(minimumTrainImagesPerClass))") }
    for split in ["validation", "test"] where (images[split]?[label] ?? 0) == 0 {
        warnings.append("\(label): no \(split) images, so it cannot be evaluated")
    }
    let count = specimens[label]?.count ?? 0
    if count < minimumSpecimensPerClass { warnings.append("\(label): \(count) distinct specimens (target ≥ \(minimumSpecimensPerClass))") }
}
if negatives.count * 5 < annotated.count { warnings.append("\(negatives.count) negative images; target ≥ 20% of labeled images") }

let pad = { (text: String, width: Int) in text.padding(toLength: width, withPad: " ", startingAt: 0) }
print(pad("class", 12) + splits.map { pad("\($0) img/box", 20) }.joined() + "specimens")
for label in labels.union(instances.values.flatMap(\.keys)).sorted() where images.values.contains(where: { $0[label] != nil }) || required.contains(label) {
    let cells = splits.map { pad("\(images[$0]?[label] ?? 0)/\(instances[$0]?[label] ?? 0)", 20) }.joined()
    print(pad(label + (required.contains(label) ? "*" : ""), 12) + cells + "\(specimens[label]?.count ?? 0)")
}
print("* mapped to a catalog product. Negatives: \(negatives.count)")
warnings.forEach { print("warning: \($0)") }
errors.forEach { print("error: \($0)") }
print(errors.isEmpty ? "OK: dataset can be imported into Create ML." : "FAILED: \(errors.count) error(s).")
exit(errors.isEmpty ? 0 : 1)
