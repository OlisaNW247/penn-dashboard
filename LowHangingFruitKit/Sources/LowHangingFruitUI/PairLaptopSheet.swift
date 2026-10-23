import SwiftUI
import LowHangingFruitKit

/// Every word the pairing sheet and Profile's "laptop" row print, in one place
/// so a test can pin them (copy rule: lowercase, short, no raw errors, no new
/// banners).
enum PairLaptopCopy {
    static let heading = "pair this laptop?"
    static let pair = "pair"
    static let notNow = "not now"
    static let failure = "couldn't pair"

    static let rowLabel = "laptop"
    static let unpair = "unpair"
    static let unpairTitle = "unpair laptop?"
    static let unpairMessage = "this phone and your laptop stop sharing. nothing is deleted."
    static let unpairFailure = "couldn't unpair"
    static let cancel = "cancel"
}

/// "pair this laptop?": shown when the phone opens a `smooth://pair` link, the
/// Chrome extension's QR code (docs/CHROME_EXTENSION.md, "Pairing").
///
/// The phone approves, not the laptop: a QR photographed off someone's screen
/// gives the photographer nothing unless their own phone says yes, and then it
/// links their laptop to their own account. So the sheet asks one plain
/// question and nothing else, and the code and key from the link are never
/// shown or logged.
///
/// A failure is the one line "couldn't pair", whatever went wrong (an expired
/// code, no network, a phone that is itself a linked device): the reasons are
/// not something a student can act on, and the laptop shows a fresh code on
/// its own. Success dismisses.
struct PairLaptopSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let link: PairingLink
    @State private var isPairing = false
    @State private var didFail = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SmoothFormHeader(title: PairLaptopCopy.heading, accent: .smoothTeal, spark: .smoothGrape)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)

                Section {
                    Button(action: pair) {
                        HStack(spacing: 10) {
                            if isPairing { ProgressView().controlSize(.small) }
                            Text(PairLaptopCopy.pair)
                        }
                    }
                    .disabled(isPairing)

                    Button(PairLaptopCopy.notNow) { dismiss() }
                        .disabled(isPairing)

                    if didFail {
                        Text(PairLaptopCopy.failure)
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothTomatoInk)
                    }
                }
                .smoothSectionBackground(.smoothTeal)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothTeal)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .lhfSheetTheme()
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isPairing)
#if os(macOS)
        .frame(minWidth: 320, minHeight: 280)
#endif
    }

    private func pair() {
        guard !isPairing else { return }
        isPairing = true
        didFail = false
        Task {
            let paired = await state.pairLaptop(link)
            isPairing = false
            if paired { dismiss() } else { didFail = true }
        }
    }
}

/// Profile → accounts: the "laptop" row, present only while the phone holds a
/// pairing key. Pairing starts from the laptop, so nothing shows when unpaired.
/// "unpair" sits behind a system confirmation, like the disconnect rows, and a
/// failure (offline) leaves the row and says so in one line.
struct ProfileLaptopRow: View {
    @EnvironmentObject private var state: AppState
    @State private var confirming = false
    @State private var isWorking = false
    @State private var didFail = false

    var body: some View {
        if state.hasPairedLaptop {
            Button {
                guard !isWorking else { return }
                confirming = true
            } label: {
                HStack(spacing: 10) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.smoothTeal)
                    }
                    Text(PairLaptopCopy.rowLabel)
                        .foregroundStyle(Color.smoothInk)
                    Spacer()
                    Text(PairLaptopCopy.unpair)
                        .font(.lhfSecondary(12, weight: .medium))
                        .foregroundStyle(Color.smoothMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityElement(children: .combine)
            .accessibilityHint("double tap to unpair")
            .alert(PairLaptopCopy.unpairTitle, isPresented: $confirming) {
                Button(PairLaptopCopy.unpair, role: .destructive) { unpair() }
                Button(PairLaptopCopy.cancel, role: .cancel) {}
            } message: {
                Text(PairLaptopCopy.unpairMessage)
            }

            if didFail {
                Text(PairLaptopCopy.unpairFailure)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }
        }
    }

    private func unpair() {
        isWorking = true
        didFail = false
        Task {
            let done = await state.unpairLaptop()
            isWorking = false
            didFail = !done
        }
    }
}
