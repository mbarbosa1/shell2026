import Foundation
import XCTest
import CatalogIntegration
import ItemRecognition
import ProductDatabase

final class VisualMappingTests: XCTestCase {
    func testBundledMappingUsesBroadMVPCategories() throws {
        let mappings = try VisualProductMappings.bundled()
        let onion = try XCTUnwrap(mappings.metadata(for: "13474244"))
        XCTAssertEqual(onion.classIDs, ["onion"])
        XCTAssertEqual(onion.modelID, ProduceCategoryClassifier.modelID)
        XCTAssertTrue(onion.allowsConfirmation)
        let taxonomy = try ProduceTaxonomy.bundled()
        for tcin in ["15014055", "85787729", "31167786"] {
            XCTAssertEqual(mappings.metadata(for: tcin)?.classIDs, ["apple"], "Apple varieties share one label")
        }
        for tcin in ["13474244", "15014055", "13219631", "54556735", "84005885"] {
            let classes = try XCTUnwrap(mappings.metadata(for: tcin)).classIDs
            XCTAssertTrue(classes.isSubset(of: Set(taxonomy.classes.keys)))
        }
        XCTAssertNil(mappings.metadata(for: "52909342"), "Onion-flavored snacks must not inherit a produce mapping")
        XCTAssertNil(mappings.metadata(for: "95193579"), "Packaged cereal with fruit imagery stays on OCR")
    }

    func testOnionAdapterKeepsDatabaseIdentityAcrossReimport() async throws {
        let db = try ProductDatabaseStore(inMemory: true)
        let data = Data("""
        {"products":[{"tcin":"13474244","title":"Fresh Yellow Onion - each",
        "locations":[{"aisle":"G10","floor":"01"}]}]}
        """.utf8)
        try await db.importProducts(data)
        let products = try await db.products()
        let onion = try XCTUnwrap(products.first)
        let adapter = try await SwiftDataCatalogReader.load(from: db, productID: onion.id,
            location: CatalogLocation(floor: "01", block: "G", aisle: 10))
        XCTAssertEqual(adapter.targetVisualMetadata?.classIDs, ["onion"])
        XCTAssertEqual(adapter.candidates.first?.id, onion.id)
        try await db.importProducts(data)
        let loaded = try await db.products()
        XCTAssertEqual(loaded.first?.id, onion.id)
        XCTAssertEqual(adapter.target.title, onion.title)
    }

    func testInvalidAndDuplicateMappingsAreRejected() {
        let entry = """
        {"tcin":"13474244","visual":{"modelID":"apple.vision.classify-image","classIDs":["onion"],"allowsConfirmation":false}}
        """
        for json in [
            "{\"version\":1,\"products\":[\(entry),\(entry)]}",
            "{\"version\":2,\"products\":[\(entry)]}",
            "{\"version\":1,\"products\":[\(entry.replacingOccurrences(of: "false", with: "true"))]}",
            "{\"version\":1,\"products\":[\(entry.replacingOccurrences(of: "[\"onion\"]", with: "[]"))]}"
        ] {
            XCTAssertThrowsError(try VisualProductMappings(data: Data(json.utf8)))
        }
        let mvp = entry.replacingOccurrences(of: VisionImageClassifier.modelID, with: ProduceCategoryClassifier.modelID)
            .replacingOccurrences(of: "false", with: "true")
        XCTAssertNoThrow(try VisualProductMappings(data: Data("{\"version\":1,\"products\":[\(mvp)]}".utf8)))
    }
}
