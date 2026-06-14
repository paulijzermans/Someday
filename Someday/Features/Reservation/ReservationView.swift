import SwiftUI

struct ReservationView: View {
    let place: Place
    var initialDate: Date = Date()
    let onComplete: () -> Void

    @State private var selectedDate: Date
    @State private var selectedTime: Date

    init(place: Place, initialDate: Date = Date(), onComplete: @escaping () -> Void) {
        self.place = place
        self.initialDate = initialDate
        self.onComplete = onComplete
        _selectedDate = State(initialValue: initialDate)
        _selectedTime = State(initialValue: initialDate)
    }
    @State private var partySize = 2
    @State private var notes = ""
    @State private var showConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if showConfirmation {
                confirmationView
            } else {
                formView
            }
        }
    }

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                placeHeader
                dateSection
                timeSection
                partySizeSection
                notesSection

                Button {
                    withAnimation(SomedayAnimations.tile) { showConfirmation = true }
                } label: {
                    Text("Confirm Reservation")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SomedayColors.lime)
                        .foregroundColor(SomedayColors.charcoal)
                        .cornerRadius(14)
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(SomedayColors.anthropicWhite)
        .navigationTitle("Reservation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SomedayColors.charcoal)
                        .frame(width: 32, height: 32)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
            }
        }
    }

    private var placeHeader: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [SomedayColors.primary, SomedayColors.primaryDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: place.category.icon)
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(place.neighborhood)
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            Spacer()
        }
        .padding(16)
        .cleanTile(cornerRadius: 16)
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Date")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            DatePicker("", selection: $selectedDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(SomedayColors.primary)
        }
        .padding(16)
        .cleanTile(cornerRadius: 16)
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .frame(height: 120)
                .tint(SomedayColors.primary)
        }
        .padding(16)
        .cleanTile(cornerRadius: 16)
    }

    private var partySizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Party size")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            HStack(spacing: 0) {
                ForEach(1...8, id: \.self) { size in
                    Button { partySize = size } label: {
                        Text("\(size)")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(partySize == size ? SomedayColors.primary : Color.clear)
                            .foregroundColor(partySize == size ? .white : SomedayColors.charcoal)
                    }
                }
            }
            .background(SomedayColors.grayLight)
            .cornerRadius(12)
        }
        .padding(16)
        .cleanTile(cornerRadius: 16)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes (optional)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            TextField("Any special requests...", text: $notes, axis: .vertical)
                .lineLimit(3...5)
                .padding(12)
                .background(SomedayColors.grayLight)
                .cornerRadius(12)
        }
        .padding(16)
        .cleanTile(cornerRadius: 16)
    }

    private var confirmationView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle().fill(SomedayColors.primaryLight).frame(width: 120, height: 120)
                Circle().fill(SomedayColors.primary).frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("Your reservation at \(place.name) is confirmed.")
                    .font(.system(size: 16))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 12) {
                confirmationRow(icon: "calendar", label: selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                confirmationRow(icon: "clock", label: selectedTime.formatted(.dateTime.hour().minute()))
                confirmationRow(icon: "person.2", label: "\(partySize) \(partySize == 1 ? "person" : "people")")
            }
            .padding(20)
            .cleanTile(cornerRadius: 16)
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onComplete) {
                Text("Back to Map")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(SomedayColors.anthropicWhite)
        .navigationBarBackButtonHidden()
    }

    private func confirmationRow(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(SomedayColors.primary)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(SomedayColors.charcoal)
            Spacer()
        }
    }
}
