import SwiftUI

/// The upgrade screen.
///
/// Deliberately plain about what stays free: the alarm itself. An alarm app that oversleeps
/// its free users to sell an upgrade earns exactly one review.
struct PaywallView: View {
    /// Which locked feature the user tapped to get here, so the screen answers the question
    /// they actually asked instead of opening on a generic pitch.
    var highlighted: ProFeature?

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    private var entitlements: EntitlementStore { appEnvironment.entitlements }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
                        .listRowBackground(Color.clear)
                }

                Section("What Pro adds") {
                    ForEach(ProFeature.allCases) { feature in
                        FeatureRow(feature: feature, isHighlighted: feature == highlighted)
                    }
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The alarm itself stays free")
                                .font(.subheadline.weight(.medium))
                            Text("Traffic-aware wake time, the leave-by backstop, and the safety rules are not behind this. They never will be.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }

                if entitlements.isAwaitingApproval {
                    Section {
                        Label(
                            "Waiting for approval. Pro unlocks as soon as the purchase is approved.",
                            systemImage: "clock.badge.questionmark"
                        )
                        .font(.subheadline)
                    }
                }

                if let message = entitlements.lastErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    buyButton
                    Button("Restore purchase") {
                        Task { await entitlements.restore() }
                    }
                    .disabled(entitlements.isWorking)
                } footer: {
                    Text("One payment, yours for good — no subscription. Everything still runs on your phone; there's no account and no server.")
                }
            }
            .navigationTitle("SmartyAlarm Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task { await entitlements.refresh() }
            .onChange(of: entitlements.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "alarm.waves.left.and.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Wake for the morning you're actually having")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Pro reads the morning ahead — your calendar and the forecast — and moves the alarm before the traffic does.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var buyButton: some View {
        Button {
            Task { await entitlements.purchase() }
        } label: {
            HStack {
                Spacer()
                if entitlements.isWorking {
                    ProgressView()
                } else if let product = entitlements.product {
                    Text("Unlock Pro — \(product.displayPrice)")
                        .fontWeight(.semibold)
                } else {
                    Text("Unlock Pro")
                        .fontWeight(.semibold)
                }
                Spacer()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(entitlements.isWorking)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

private struct FeatureRow: View {
    let feature: ProFeature
    let isHighlighted: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.subheadline.weight(isHighlighted ? .semibold : .regular))
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: feature.symbolName)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 2)
    }
}

/// A tappable "Pro" chip for locked rows.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
            .accessibilityLabel("Requires Pro")
    }
}
