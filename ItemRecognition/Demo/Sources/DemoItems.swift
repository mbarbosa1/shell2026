import Foundation
import ItemRecognition

/// A preset test target, copied from `Scripts/output/products.json` so the demo needs no database.
/// Produce with a `visualClass` is recognized by appearance; everything else is read with OCR.
struct DemoItem: Identifiable, Hashable, Sendable {
    let tcin: String
    let title: String
    let itemType: String
    /// Store location as the app shows it, e.g. "G44".
    let location: String
    /// Produce taxonomy class (`produce-taxonomy.json`), or nil for packaged goods.
    let visualClass: String?
    /// What a shopper would type on the grocery list for this product; the scan's reference words.
    let listEntry: String

    /// Stable per TCIN, so the same item keeps its id across launches.
    var id: UUID { UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - tcin.count) + tcin)! }

    var recognizesByAppearance: Bool { visualClass != nil }

    var snapshot: CatalogItemSnapshot {
        CatalogItemSnapshot(
            id: id, catalogKey: tcin, displayName: title, brand: nil,
            normalizedTerms: TextNormalizer().tokens(from: title),
            visual: visualClass.map {
                VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: [$0], allowsConfirmation: true)
            },
            itemType: itemType
        )
    }
}

extension DemoItem {
    /// Common items from the bundled Target capture. Lookalike pairs (Doritos, Oreo) share an
    /// aisle on purpose: the matcher must lead the neighbor by 15 points to ask the shopper.
    static let all: [DemoItem] = [
        DemoItem(tcin: "13474244", title: "Fresh Yellow Onion - each", itemType: "Vegetables", location: "G10", visualClass: "onion", listEntry: "yellow onion"),
        DemoItem(tcin: "15013944", title: "Fresh Banana - each - Good & Gather™", itemType: "Fruit", location: "G9", visualClass: "banana", listEntry: "bananas"),
        DemoItem(tcin: "15014055", title: "Fresh Gala Apple - each", itemType: "Fruit", location: "G9", visualClass: "apple", listEntry: "gala apple"),
        DemoItem(tcin: "94769016", title: "Large Hass Avocado - each", itemType: "Fruit", location: "G10", visualClass: "avocado", listEntry: "avocado"),
        DemoItem(tcin: "84004243", title: "Fresh Limes - 1lb Bag - Good & Gather™", itemType: "Fruit", location: "G7", visualClass: "lime", listEntry: "limes"),
        DemoItem(tcin: "84005885", title: "Fresh Navel Oranges - 4lb Bag - Good & Gather™", itemType: "Fruit", location: "G9", visualClass: "orange", listEntry: "navel oranges"),
        DemoItem(tcin: "54556735", title: "Fresh Baby-Cut Carrots - 1lb - Good & Gather™", itemType: "Vegetables", location: "G6", visualClass: "carrot", listEntry: "baby carrots"),
        DemoItem(tcin: "13276204", title: "2% Reduced Fat Milk - 1gal - Good & Gather™", itemType: "Milk and Buttermilk", location: "G44", visualClass: nil, listEntry: "2% milk"),
        DemoItem(tcin: "14713534", title: "Grade A Large Eggs - 12ct - Good & Gather™ (Packaging May Vary)", itemType: "Eggs", location: "G44", visualClass: nil, listEntry: "large eggs"),
        DemoItem(tcin: "13227061", title: "Land O Lakes Salted Butter - 1lb/4ct: Whole Milk Fat, Cow Milk Source", itemType: "Butter", location: "G15", visualClass: nil, listEntry: "Land O Lakes salted butter"),
        DemoItem(tcin: "13009781", title: "Cheez-It Original Baked Snack Crackers - 12.4oz", itemType: "Crackers", location: "G34", visualClass: nil, listEntry: "Cheez-It"),
        DemoItem(tcin: "14930889", title: "Doritos Nacho Cheese Tortilla Chips - 9.25oz", itemType: "Chips, Puffs and Pretzels", location: "G32", visualClass: nil, listEntry: "Doritos Nacho Cheese"),
        DemoItem(tcin: "12992579", title: "Doritos Cool Ranch Tortilla Chips - 9.25oz", itemType: "Chips, Puffs and Pretzels", location: "G32", visualClass: nil, listEntry: "Doritos Cool Ranch"),
        DemoItem(tcin: "87471453", title: "Oreo Chocolate Sandwich Cookies Size - 18.12oz", itemType: "Cookies and Bars", location: "G28", visualClass: nil, listEntry: "Oreo chocolate cookies"),
        DemoItem(tcin: "87471681", title: "Oreo Golden Sandwich Cookies Size - 18.12oz", itemType: "Cookies and Bars", location: "G28", visualClass: nil, listEntry: "Golden Oreo"),
        DemoItem(tcin: "86434942", title: "Quaker Instant Oatmeal Maple Brown Sugar 8ct: 100 Percent Whole Grain, No Artificial Sweeteners", itemType: "Porridges", location: "G26", visualClass: nil, listEntry: "Quaker maple brown sugar oatmeal"),
        DemoItem(tcin: "89529230", title: "Kellogg's Corn Pops Breakfast Cereal - 16.4oz: No High Fructose Corn Syrup", itemType: "Cold Cereals", location: "G27", visualClass: nil, listEntry: "Corn Pops cereal"),
    ]

    static func named(_ id: UUID?) -> DemoItem? { all.first { $0.id == id } }
}

/// Stands in for the SwiftData adapter: every preset item is a candidate, so a read of the
/// neighbor's package can win the match, and the rule comes from the calibration panel.
struct DemoCatalog: CatalogReading {
    let rule: DetectionActivationRuleSnapshot

    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        DemoItem.all.map(\.snapshot)
    }

    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        targetItemID == rule.targetItemID ? rule : nil
    }
}
