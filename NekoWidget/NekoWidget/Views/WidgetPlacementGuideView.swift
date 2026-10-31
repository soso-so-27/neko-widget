import SwiftUI

/// A compact handoff from the app to the user-controlled Home Screen flow.
/// iOS doesn't expose an API for placing a Home Screen widget, so the guide
/// shows only the three actions the user needs and lets the owner recheck the
/// installed configuration when the app becomes active again.
struct WidgetPlacementGuideView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void
    @State private var page = 0

    /// One picture per step: the iOS screens the person will see, in order.
    private var steps: [(image: String, text: String)] {
        if #available(iOS 18.0, *) {
            Array(zip(["onboarding-widget-step-1", "onboarding-widget-step-2-ios18", "onboarding-widget-step-3"],
                      OnboardingPresentationCopy.widgetModernPlacementSteps))
        } else {
            Array(zip(["onboarding-widget-step-1", "onboarding-widget-step-3", "onboarding-widget-step-4"],
                      OnboardingPresentationCopy.widgetLegacyPlacementSteps))
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(OnboardingPresentationCopy.widgetTitleLines.joined(separator: ""))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)

            // The pictures do the explaining; one line under each.
            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 12) {
                        Image(step.image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.5))
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text((index + 1).formatted())
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.accentColor, in: Circle())
                            Text(step.text)
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("手順\(index + 1)。\(step.text)")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .accessibilityIdentifier("widget-placement-steps")

            Text("置いたウィジェットを長押しして「この子のくもりのまど」を選ぶと、押して晴らす、きょうの1枚になります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: onComplete) {
                    Text(OnboardingPresentationCopy.widgetAction)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("widget-placement-complete")

                Button(OnboardingPresentationCopy.widgetLaterAction, action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("widget-placement-skip")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct WidgetPlacementStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: Circle())

            Text(text)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("手順\(number)。\(text)")
    }
}
