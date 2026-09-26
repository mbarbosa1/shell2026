import SwiftData
import SwiftUI

struct ContentView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case aisle = "By Aisle"
        case name = "A–Z"
        var id: Self { self }
    }

    @Query(sort: [SortDescriptor(\StoreLocation.block), SortDescriptor(\StoreLocation.aisle)])
    private var locations: [StoreLocation]

    @Query(sort: \Product.title)
    private var products: [Product]

    @State private var grouping: Grouping = .aisle
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                switch grouping {
                case .aisle:
                    ForEach(aisleSections, id: \.label) { section in
                        Section {
                            ForEach(section.products) { product in
                                row(for: product)
                            }
                        } header: {
                            Text("Aisle \(section.label)")
                        }
                    }
                case .name:
                    ForEach(filtered(products)) { product in
                        row(for: product)
                    }
                }
            }
            .navigationTitle("Products (\(products.count))")
            .navigationDestination(for: Product.self) { ProductDetailView(product: $0) }
            .searchable(text: $searchText, prompt: "Search products or aisles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        CalibrationView()
                    } label: {
                        Label("Calibrate", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                ToolbarItem {
                    Picker("Group", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .overlay {
                if products.isEmpty {
                    ContentUnavailableView("No Products", systemImage: "cart",
                                           description: Text("Run Scripts/run.sh to generate products.json."))
                }
            }
        }
    }

    private func row(for product: Product) -> some View {
        NavigationLink(value: product) {
            ProductRow(product: product)
        }
    }

    /// Products grouped by aisle label ("G44"); a product stocked in two aisles appears in both.
    private var aisleSections: [(label: String, products: [Product])] {
        var order: [String] = []
        var byLabel: [String: [Product]] = [:]
        for location in locations {
            guard let product = location.product, matches(product) || matches(location.label) else { continue }
            if byLabel[location.label] == nil { order.append(location.label) }
            if !(byLabel[location.label]?.contains(product) ?? false) {
                byLabel[location.label, default: []].append(product)
            }
        }
        return order.map { ($0, byLabel[$0]!.sorted { $0.title < $1.title }) }
    }

    private func filtered(_ products: [Product]) -> [Product] {
        products.filter { matches($0) || $0.locations.contains { matches($0.label) } }
    }

    private func matches(_ product: Product) -> Bool {
        searchText.isEmpty || product.title.localizedCaseInsensitiveContains(searchText)
    }

    private func matches(_ label: String) -> Bool {
        !searchText.isEmpty && label.localizedCaseInsensitiveCompare(searchText) == .orderedSame
    }
}

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(url: product.primaryImageURL, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(product.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    PriceText(product: product)
                    ForEach(product.locations.map(\.label).uniqued(), id: \.self) { label in
                        LocationBadge(label: label)
                    }
                    StockText(product: product)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LocationBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.monospaced().bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red.opacity(0.15), in: .capsule)
            .foregroundStyle(.red)
    }
}

struct PriceText: View {
    let product: Product

    var body: some View {
        if let price = product.formattedPrice {
            HStack(spacing: 4) {
                Text(price)
                    .font(.subheadline.bold())
                    .foregroundStyle(product.isOnSale ? .red : .primary)
                if product.isOnSale, let regular = product.regularPrice {
                    Text(regular, format: .currency(code: "USD"))
                        .font(.caption)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StockText: View {
    let product: Product

    var body: some View {
        if product.soldOut == true {
            Text("Sold out").font(.caption).foregroundStyle(.secondary)
        } else if let quantity = product.quantityAvailable {
            Text("\(Int(quantity)) in stock").font(.caption).foregroundStyle(.green)
        }
    }
}

struct ProductImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.map { scene7($0, width: Int(size * 3)) }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .background(.white, in: .rect(cornerRadius: 8))
    }

    /// Target's image CDN resizes on request; ask for roughly the size we draw.
    private func scene7(_ url: URL, width: Int) -> URL {
        URL(string: "\(url.absoluteString)?wid=\(width)&hei=\(width)&fmt=pjpeg") ?? url
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Product.self, StoreLocation.self], inMemory: true)
}
