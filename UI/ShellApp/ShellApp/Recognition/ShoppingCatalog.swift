import Foundation
import ItemRecognition

/// One item on the list for the camera to look for, as plain values the recognizer can use off the
/// main actor. Built from the list item and the catalog when its stop is reached, never per frame.
struct ScanTarget {
    /// The `GroceryItem` on the list.
    let listItemID: UUID
    let name: String
    /// What the user put on the list. The label is read for these words, and "Is this …?" names it.
    let query: GroceryQuery
    let catalog: ShoppingCatalog

    /// Nil when the item isn't linked to a catalog product (the store doesn't carry it).
    /// `landmark` is the stop's reference node, where detection starts; it stays on for
    /// `windowMeters` past it.
    @MainActor
    init?(item: GroceryItem, products: [Product], landmark: String, windowMeters: Double) {
        guard let tcin = item.tcin, let product = products.first(where: { $0.tcin == tcin }) else { return nil }
        listItemID = item.id
        name = item.name
        query = GroceryQuery(name: item.name, brand: item.brand, label: item.label)
        catalog = ShoppingCatalog(target: product, listName: item.name, spot: item.location,
                                  products: products, landmark: landmark, windowMeters: windowMeters)
    }
}

/// The recognizer's view of the catalog for one item: its product, and every other product stocked
/// at the same spot, so a lookalike beside it (Doritos Cool Ranch next to Nacho Cheese) isn't taken
/// for it. Detection turns on at the reference node and stays on for the stop's lane.
struct ShoppingCatalog: CatalogReading {
    let targetID: UUID
    let candidates: [CatalogItemSnapshot]
    let rule: DetectionActivationRuleSnapshot

    /// Loose fruit and vegetables are recognized by how they look; everything else by its label.
    var recognizesByAppearance: Bool {
        candidates.first { $0.id == targetID }.map { $0.recognizesByAppearance && $0.visual != nil } ?? false
    }

    private static let taxonomy = try? ProduceTaxonomy.bundled()

    @MainActor
    fileprivate init(target: Product, listName: String, spot: String?, products: [Product],
                     landmark: String, windowMeters: Double) {
        let spots = Set(target.locations.map(\.label) + [spot].compactMap { $0 })
        let neighbors = products.filter { $0.tcin != target.tcin && $0.locations.contains { spots.contains($0.label) } }
        // The recognizer only needs ids that stay put for this scan.
        let targetID = UUID()
        self.targetID = targetID
        candidates = [Self.snapshot(of: target, id: targetID, listName: listName)]
            + neighbors.map { Self.snapshot(of: $0, id: UUID(), listName: nil) }
        rule = DetectionActivationRuleSnapshot(targetItemID: targetID, landmarkID: landmark,
                                               activateAfterMeters: 0, deactivateAfterMeters: windowMeters)
    }

    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        candidates
    }

    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        targetItemID == targetID ? rule : nil
    }

    @MainActor
    private static func snapshot(of product: Product, id: UUID, listName: String?) -> CatalogItemSnapshot {
        let normalizer = TextNormalizer()
        let texts = [product.title] + [product.brand].compactMap { $0 }
        return CatalogItemSnapshot(
            id: id, catalogKey: product.tcin, displayName: product.title, brand: product.brand,
            normalizedTerms: Set(texts.flatMap { normalizer.tokens(from: $0) }),
            visual: produceClass(of: product, listName: listName).map {
                VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: [$0], allowsConfirmation: true)
            },
            itemType: product.itemType
        )
    }

    /// "Bananas" → `banana`. Tries the name on the list first, then the start of the catalog title
    /// ("Fresh Banana" from "Fresh Banana - each - Good & Gather™"). Nil for anything but produce.
    @MainActor
    private static func produceClass(of product: Product, listName: String?) -> String? {
        let type = product.itemType?.lowercased() ?? ""
        guard type == "fruit" || type.hasPrefix("vegetable"), let taxonomy else { return nil }
        let title = product.title.components(separatedBy: " - ").first ?? product.title
        return [listName, title].compactMap { $0 }.lazy.compactMap(taxonomy.classID(forItemName:)).first
    }
}
