import SwiftUI

/// Full-screen camera. The mount aims the phone, so the only things on top of the feed
/// are the small "Still to get" and "In your cart" panels and the X to leave, plus, at a stop,
/// what the camera is looking for and the camera's "Is this …?" while it waits for an answer.
/// The feed is `AppModel`'s ARKit session, started by "Start shopping".
struct CameraScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if model.camera.isRunning {
                CameraPreview(session: model.camera.session)
                    .ignoresSafeArea()
            }

            VStack(spacing: 8) {
                if let question = model.scanner.question {
                    ScanQuestionCard(question: question)
                }
                ToGetPanel()
                CartPanel()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) {
            if let target = model.scanner.target {
                ScanTargetPill(name: target.name, meters: model.scanner.objectMeters)
                    .padding(.leading, 16)
                    // Clear of the X: its 56 pt button, its 16 pt margin, and a gap.
                    .padding(.trailing, 80)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { model.endShopping() } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .padding(.trailing, 16)
            .accessibilityLabel("Close camera")
            .accessibilityHint("Stops shopping directions and closes the camera")
        }
        .accessibilityAction(.escape) { model.endShopping() }
    }
}

/// What the camera is looking for at this stop, and how far the object in view is from the phone.
/// A second check for anyone who can see some of the screen: it's read when VoiceOver lands on
/// it, but never announced.
private struct ScanTargetPill: View {
    let name: String
    /// Nil with no object in view.
    let meters: Double?

    /// "1.2"
    private var figure: String? {
        meters.map { $0.formatted(.number.precision(.fractionLength(1))) }
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(figure.map { "\($0) m" } ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(meters == nil ? Theme.textSecondary : Theme.accentText)
                .contentTransition(.numericText())
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.94), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14))
        }
        .animation(.snappy, value: figure)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Looking for \(name)")
        .accessibilityValue(figure.map { "\($0) meters away" } ?? "No object in view")
    }
}

/// The camera found what looks like the item: yes puts it in the cart, no keeps looking.
/// The question is also spoken, and can be answered by voice.
private struct ScanQuestionCard: View {
    @Environment(AppModel.self) private var model
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Button("No") { model.answerScan(false) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Keeps looking")
                Button("Yes") { model.answerScan(true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Puts it in your cart")
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(14)
        .background(Theme.background.opacity(0.94), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accentText)
        }
    }
}

/// "In your cart" panel from the Figma camera frame.
struct CartPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("In your cart")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(model.cart.count == 1 ? "1 item" : "\(model.cart.count) items")
                    .font(.footnote)
                    .foregroundStyle(Theme.accentText)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.cart) { item in
                        CartRow(item: item, isJustAdded: item.id == model.justAddedCartID)
                    }
                }
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.background.opacity(0.94), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14))
        }
        .animation(.snappy, value: model.cart)
    }
}

/// What's left on the list, with where to find each item ("G44" = block G, aisle 44).
struct ToGetPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.itemsToGet
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Still to get")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(items.count == 1 ? "1 item" : "\(items.count) items")
                        .font(.footnote)
                        .foregroundStyle(Theme.accentText)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            ToGetRow(item: item)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .background(Theme.background.opacity(0.94), in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14))
            }
            .animation(.snappy, value: items)
        }
    }
}

private struct ToGetRow: View {
    let item: GroceryItem

    var body: some View {
        HStack(spacing: 8) {
            Text(item.quantity > 1 ? "\(item.quantity) × \(item.name)" : item.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.location ?? "Not in store map")
                .font(item.location == nil ? .caption : .subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(item.location == nil ? Theme.textSecondary : Theme.accentText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.block.flatMap { block in item.aisle.map { "Block \(block), aisle \($0)" } } ?? "Not in the store map")
    }
}

private struct CartRow: View {
    let item: GroceryItem
    let isJustAdded: Bool

    /// "Quaker · Rolled oats"
    private var title: String {
        [item.brand, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            if isJustAdded {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(isJustAdded ? "Just added · \(item.quantity)" : "\(item.quantity)")
                .font(isJustAdded ? .caption : .subheadline)
                .foregroundStyle(isJustAdded ? Theme.success : Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isJustAdded ? 10 : 8)
        .background(isJustAdded ? Theme.cardRaised : .clear, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CameraScreen()
        .environment(AppModel.preview)
}
