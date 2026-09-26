import SwiftUI

enum AppTab: Hashable {
    case shop, history
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .shop

    var body: some View {
        @Bindable var model = model

        ZStack {
            switch tab {
            case .shop: ShopView()
            case .history: HistoryView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            ShellTabBar(selection: $tab)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
        .background(Theme.background.ignoresSafeArea())
        .listeningGlow(model.isListening)
        .fullScreenCover(isPresented: $model.isCameraOpen) {
            CameraScreen()
        }
    }
}

/// The two-tab bar from the Figma: a rounded container with a raised pill on the selected tab.
struct ShellTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.shop, title: "Shop", symbol: "waveform")
            tabButton(.history, title: "History", symbol: "clock.arrow.circlepath")
        }
        .padding(6)
        .background(Theme.card, in: .rect(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.hairline)
        }
    }

    private func tabButton(_ tab: AppTab, title: String, symbol: String) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(isSelected ? Theme.cardRaised : .clear, in: .rect(cornerRadius: 20))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    RootView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
