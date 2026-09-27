import Foundation
import SwiftData
import XCTest
import CatalogIntegration
import ItemRecognition
@testable import ProductDatabase

final class CatalogIntegrationTests: XCTestCase {
    private let location = CatalogLocation(floor: "01", block: "G", aisle: 44)

    private func data(title: String = "2% Milk 1gal", locations: Bool = true) -> Data {
        Data("""
        {"products":[
        {"tcin":"milk","title":"\(title)","soldOut":true,"quantityAvailable":0,
         "locations":\(locations ? "[{\"aisle\":44,\"block\":\"G\",\"floor\":\"01\"}]" : "[]")},
        {"tcin":"whole","title":"Whole Milk 1gal","locations":[{"aisle":44,"block":"G","floor":"01"}]},
        {"tcin":"bread","title":"Wheat Bread","locations":[{"aisle":12,"block":"G","floor":"01"}]}]}
        """.utf8)
    }
    private func seeded() async throws -> (ProductDatabaseStore, CatalogProductRecord) {
        let db = try ProductDatabaseStore(inMemory: true)
        try await db.importProducts(data())
        let products = try await db.products()
        return (db, try XCTUnwrap(products.first { $0.tcin == "milk" }))
    }
    private func save(_ db: ProductDatabaseStore, _ target: UUID, start: Double = 3, end: Double = 20, carried: Bool = true) async throws {
        try await db.saveActivation(productID: target, location: location,
            landmark: "G44-top", start: start, end: end, side: "left", isInStore: carried)
    }

    func testRepeatedImportPreservesIdentityNamesAndRule() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        let skipped = try await db.importProducts(data())
        XCTAssertFalse(skipped)
        try await db.importProducts(data(title: "Updated Milk 1gal"))
        let records = try await db.sessionRecords(productID: product.id, location: location)
        XCTAssertEqual(records.target.title, "Updated Milk 1gal")
        XCTAssertEqual(records.target.id, product.id)
        XCTAssertEqual(records.activation?.start, 3)
        let products = try await db.products()
        XCTAssertEqual(products.count, 3)
    }

    func testPartialImportDoesNotDeleteLocationIdentityOrProductName() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        try await db.importProducts(Data("{\"products\":[{\"tcin\":\"milk\",\"locations\":[]}]}".utf8))
        let record = try await db.sessionRecords(productID: product.id, location: location)
        XCTAssertEqual(record.target.title, product.title)
        XCTAssertEqual(record.target.locations, [location])
        XCTAssertNotNil(record.activation)
        let products = try await db.products()
        XCTAssertEqual(products.count, 3, "Missing rows in a partial capture are not deletions")
    }

    func testAdapterLoadsOnlySelectedAisleAndMissingRuleKeepsGateOff() async throws {
        let (db, product) = try await seeded()
        let adapter = try await SwiftDataCatalogReader.load(from: db, productID: product.id, location: location)
        XCTAssertEqual(Set(adapter.candidates.map(\.catalogKey)), ["milk", "whole"])
        XCTAssertNil(adapter.rule)
        let gate = ActivationGate(catalog: adapter)
        let decision = try await gate.evaluate(context(product.id, meters: 5))
        XCTAssertEqual(decision.inactiveReason, .missingActivationRule)
    }

    func testStockZeroDoesNotOverrideConfiguredStoreMembership() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        let adapter = try await SwiftDataCatalogReader.load(from: db, productID: product.id, location: location)
        XCTAssertTrue(try XCTUnwrap(adapter.rule).isInStore)
        let active = try await ActivationGate(catalog: adapter).evaluate(context(product.id, meters: 3))
        XCTAssertTrue(active.isDetectionActive)
    }

    func testRuleEditRequiresFreshSnapshotAndChangesThreshold() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        let old = try await SwiftDataCatalogReader.load(from: db, productID: product.id, location: location)
        try await save(db, product.id, start: 10)
        let fresh = try await SwiftDataCatalogReader.load(from: db, productID: product.id, location: location)
        XCTAssertEqual(old.rule?.activateAfterMeters, 3)
        XCTAssertEqual(fresh.rule?.activateAfterMeters, 10)
        let decision = try await ActivationGate(catalog: fresh).evaluate(context(product.id, meters: 5))
        XCTAssertEqual(decision.state, .armed)
    }

    func testCombinedAisleImportsWithoutDuplicatingLegacyLocationOrRule() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        try await db.importProducts(Data("""
        {"products":[{"tcin":"milk","locations":[{"aisle":"G44","floor":"01"}]}]}
        """.utf8))
        let records = try await db.sessionRecords(productID: product.id, location: location)
        XCTAssertEqual(records.target.locations, [location])
        XCTAssertEqual(records.activation?.landmarkID, "G44-top")
        let dto = try JSONDecoder().decode(ProductFileDTO.self, from: Data("""
        {"products":[{"tcin":"example","locations":[{"aisle":"A23","floor":"01"}]}]}
        """.utf8))
        XCTAssertEqual(dto.products.first?.locations?.first?.aisle, "A23")
        XCTAssertTrue(dto.products.first?.hasLocation == true)
    }

    func testCatalogImportsWithoutStoreMetadata() async throws {
        let (db, product) = try await seeded()
        try await save(db, product.id)
        let records = try await db.sessionRecords(productID: product.id, location: location)
        XCTAssertEqual(records.target.id, product.id)
        XCTAssertEqual(records.activation?.landmarkID, "G44-top")
    }

    func testInvalidRulesAndUnknownLocationAreRejected() async throws {
        let (db, product) = try await seeded()
        for (start, end) in [(Double.nan, 20), (-1, 20), (10, 3), (0, Double.infinity)] {
            do { try await save(db, product.id, start: start, end: end); XCTFail("Must reject invalid distances") }
            catch { XCTAssertEqual(error as? CatalogDatabaseError, .invalidRule) }
        }
        do {
            _ = try await db.sessionRecords(productID: product.id, location: CatalogLocation(floor: "01", block: "G", aisle: 45))
            XCTFail("Must not pick a different location")
        } catch { XCTAssertEqual(error as? CatalogDatabaseError, .invalidLocation) }
    }

    func testIdentityAndActivationSurviveReopeningPersistentStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.store")
        let first = try ProductDatabaseStore(storageURL: url)
        try await first.importProducts(data())
        let products = try await first.products()
        let product = try XCTUnwrap(products.first { $0.tcin == "milk" })
        try await save(first, product.id)
        let reopened = try ProductDatabaseStore(storageURL: url)
        let records = try await reopened.sessionRecords(productID: product.id, location: location)
        XCTAssertEqual(records.target.id, product.id)
        XCTAssertEqual(records.activation?.landmarkID, "G44-top")
    }

    func testDuplicateImportIDsAreRejectedBeforeMutation() async throws {
        let (db, _) = try await seeded()
        do {
            try await db.importProducts(Data("{\"products\":[{\"tcin\":\"milk\"},{\"tcin\":\"milk\"}]}".utf8))
            XCTFail("Duplicate IDs must fail")
        } catch { XCTAssertEqual(error as? CatalogDatabaseError, .invalidProductID) }
        let products = try await db.products()
        XCTAssertEqual(products.count, 3)
    }

    func testExistingProductOnlyStoreUpgradesWithoutLosingRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.store")
        try autoreleasepool {
            let schema = Schema([Product.self, StoreLocation.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("ProductCatalog", schema: schema, url: url)])
            let context = ModelContext(container)
            context.insert(Product(tcin: "legacy", title: "Existing saved product"))
            try context.save()
        }
        let upgraded = try ProductDatabaseStore(storageURL: url)
        try await upgraded.importProducts(data())
        let products = try await upgraded.products()
        XCTAssertEqual(products.count, 4)
        XCTAssertEqual(products.first { $0.tcin == "legacy" }?.title, "Existing saved product")
    }

    func testTwoLocationsKeepIndependentRules() async throws {
        let (db, product) = try await seeded()
        let second = CatalogLocation(floor: "02", block: "B", aisle: 1)
        try await db.importProducts(Data("""
        {"products":[{"tcin":"milk","locations":[{"floor":"02","block":"B","aisle":1}]}]}
        """.utf8))
        try await save(db, product.id)
        try await db.saveActivation(productID: product.id, location: second,
            landmark: "B1-entry", start: 10, end: 15, side: "right", isInStore: false)
        let first = try await db.sessionRecords(productID: product.id, location: location)
        let other = try await db.sessionRecords(productID: product.id, location: second)
        XCTAssertEqual(first.activation?.start, 3)
        XCTAssertEqual(other.activation?.start, 10)
        XCTAssertEqual(other.activation?.side, "right")
        XCTAssertFalse(try XCTUnwrap(other.activation).isInStore)
    }

    func testBundledCatalogImportsAndPreservesRecordCount() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("output/products.json"))
        let dto = try JSONDecoder().decode(ProductFileDTO.self, from: data)
        let db = try ProductDatabaseStore(inMemory: true)
        try await db.importProducts(data)
        let records = try await db.products()
        XCTAssertEqual(records.count, dto.products.count)
        XCTAssertTrue(records.contains { !$0.locations.isEmpty })
    }

    private func context(_ id: UUID, meters: Double) -> RecognitionContext {
        RecognitionContext(targetItemID: id, landmarkProgress: LandmarkProgressObservation(timestamp: 1,
            passedLandmarkID: "G44-top", metersPastLandmark: meters, isReliable: true), externalPause: false)
    }
}
