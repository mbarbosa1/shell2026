import Foundation

/// A calibration session exported by the calibration app (`shell-calibration-v2`): named nodes at
/// the positions they were marked, and the walked length of each edge between them.
///
/// Positions are meters seen from above, as [x, z]: x to the right and z backward, relative to
/// wherever the phone was when that session opened. So every file has its own frame, and joining
/// files means turning and moving them into one (see `StoreMap.target`).
struct CalibrationFile: Decodable {
    struct Node: Decodable {
        let id: String
        let name: String
        let position: [Double]
    }

    struct Edge: Decodable {
        let id: String
        let from: String
        let to: String
        let lengthMeters: Double
    }

    let store: String
    let nodes: [Node]
    let edges: [Edge]

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// A file shipped in the app's Calibration folder, by name without ".json".
    static func bundled(_ name: String) -> CalibrationFile? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json")
                ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Calibration"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CalibrationFile.self, from: data)
    }
}
