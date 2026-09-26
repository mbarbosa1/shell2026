import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("History")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Your trips. Your usuals.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)

                    usualsSection
                        .padding(.top, 20)

                    tripsSection
                        .padding(.top, 24)

                    Label("Say “Read my last trip.”", systemImage: "speaker.wave.2")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: GroceryList.self) { trip in
                TripDetailView(trip: trip)
            }
        }
    }

    private var usualsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your usuals")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Brands and labels you ask for most.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            if model.usuals.isEmpty {
                Text("Items you add to two or more lists show up here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(model.usuals) { usual in
                    GroceryRow(item: usual, isChecked: model.isOnList(usual))
                }
                Button("Add usuals to my list") { model.addUsualsToList() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent trips")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if model.trips.isEmpty {
                Text("Finished lists show up here. Say “I’m done shopping.”")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(model.trips) { trip in
                NavigationLink(value: trip) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.date, format: .dateTime.month(.wide).day())
                                .font(.headline)
                            Text(trip.summary)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 6)
                    .cardStyle()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TripDetailView: View {
    let trip: GroceryList

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(trip.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(trip.sortedItems) { item in
                    GroceryRow(item: item, isChecked: item.isCollected)
                }

                if !trip.history.isEmpty {
                    Text("History")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 16)
                    ForEach(trip.sortedHistory) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.text)
                            Spacer()
                            if event.source == .voice {
                                Image(systemName: "waveform")
                                    .accessibilityLabel("By voice")
                            }
                            Text(event.date, format: .dateTime.hour().minute())
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text(trip.date, format: .dateTime.month(.wide).day()))
        .toolbar(.visible, for: .navigationBar)
    }
}
