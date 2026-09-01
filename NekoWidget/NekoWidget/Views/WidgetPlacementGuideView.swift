import SwiftUI

/// A compact handoff from the app to the user-controlled Home Screen flow.
/// iOS doesn't expose an API for placing a Home Screen widget, so the guide
/// shows only the three actions the user needs and lets the owner recheck the
/// installed configuration when the app becomes active again.
struct WidgetPlacementGuideView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    private var placementSteps: [String] {
        if #available(iOS 18.0, *) {
            OnboardingPresentationCopy.widgetModernPlacementSteps
        } else {
            OnboardingPresentationCopy.widgetLegacyPlacementSteps
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 68, height: 68)
                        .background(
                            Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 20)
                        )

                    Text(
                        OnboardingPresentationCopy.widgetTitleLines
                            .joined(separator: "\n")
                    )
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)

                    Text(OnboardingPresentationCopy.widgetBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    ForEach(Array(placementSteps.enumerated()), id: \.offset) { index, step in
                        WidgetPlacementStepRow(number: index + 1, text: step)

                        if index < placementSteps.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .accessibilityIdentifier("widget-placement-steps")

                Label(
                    OnboardingPresentationCopy.widgetReturnHint,
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("widget-placement-skip")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
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
