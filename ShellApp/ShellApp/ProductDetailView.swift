import SwiftUI

struct ProductDetailView: View {
    let product: Product

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach([product.primaryImageURL].compactMap { $0 } + product.alternateImageURLs, id: \.self) { url in
                            ProductImage(url: url, size: 220)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel(product.imageAltText ?? product.title)

                Text(product.title).font(.headline)
                if let parent = product.parentTitle {
                    Text(parent).font(.subheadline).foregroundStyle(.secondary)
                }
                if let alt = product.imageAltText {
                    Text(alt).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Price") {
                if let price = product.formattedPrice {
                    LabeledContent("Price") { PriceText(product: product) }
                        .accessibilityValue(price)
                }
                if let unit = product.unitPrice {
                    LabeledContent("Unit Price", value: unit + (product.unitPriceSuffix ?? ""))
                }
            }

            Section("Where to Find It") {
                ForEach(product.locations.sorted { ($0.block, $0.aisle) < ($1.block, $1.aisle) }) { location in
                    HStack {
                        LocationBadge(label: location.label)
                        Text("Block \(location.block), Aisle \(location.aisle)")
                        Spacer()
                        Text("Floor \(location.floor)").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Stock") {
                LabeledContent("Sold Out", value: product.soldOut == true ? "Yes" : "No")
                if let quantity = product.quantityAvailable {
                    LabeledContent("Quantity at Store", value: "\(Int(quantity))")
                }
            }

            Section("Details") {
                LabeledContent("TCIN", value: product.tcin)
                if let type = product.itemType {
                    LabeledContent("Type", value: type)
                }
                if let typeId = product.itemTypeId {
                    LabeledContent("Type ID", value: typeId)
                }
                if let url = product.buyURL {
                    Link("View on target.com", destination: url)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(product.locationLabel ?? "Product")
    }
}
