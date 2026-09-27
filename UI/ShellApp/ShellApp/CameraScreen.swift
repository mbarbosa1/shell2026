import SwiftUI

/// Full-screen camera. The mount aims the phone, so the only things on top of the feed
/// are the small "In your cart" panel and the X to leave.
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

            CartPanel()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
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
