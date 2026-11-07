import SwiftUI

/// A compact handoff from the app to the user-controlled Home Screen flow.
/// iOS doesn't expose an API for placing a Home Screen widget, so the guide
/// shows only the three actions the user needs and lets the owner recheck the
/// installed configuration when the app becomes active again.
struct WidgetPlacementGuideView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void
    /// Cats are already registered: the line about registering is left out.
    var hasCats = false
    /// Opened again from 設定: one button with this title (it calls
    /// `onComplete`) in place of 「完了」 and 「あとで」 (11/7).
    var closeTitle: String? = nil
    /// An official window just received: the last line says to choose it in
    /// the Widget (11/7: one guide for every place, not a second one).
    var windowName: String? = nil
    @State private var page = 0

    /// One picture per step: the iOS screens the person will see, in order.
    /// 11/7: the clouded window and its tag are the last step (it was a small
    /// grey note under the pages). An image name starting with "sf:" is a symbol.
    private var steps: [(image: String, text: String)] {
        let cloudy: [(image: String, text: String)] = windowName == nil
            ? [(image: "sf:cloud.fill", text: "置いたら、そのままくもりのまどです。札を押すと、きょうの1枚が出ます。")] : []
        return placementSteps + cloudy
    }

    private var placementSteps: [(image: String, text: String)] {
        if #available(iOS 18.0, *) {
            Array(zip(["onboarding-widget-step-1", "onboarding-widget-step-2-ios18", "onboarding-widget-step-3"],
                      OnboardingPresentationCopy.widgetModernPlacementSteps))
        } else {
            // No screenshot of iOS 17's 「＋」: a symbol there, and the search
            // screen for the last step (11/6: the pictures were one step off).
            Array(zip(["onboarding-widget-step-1", "", "onboarding-widget-step-3"],
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
                        Group {
                            if step.image.isEmpty {
                                Image(systemName: "plus.square.fill")
                                    .font(.system(size: 96))
                                    .foregroundStyle(.tint)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if step.image.hasPrefix("sf:") {
                                Image(systemName: String(step.image.dropFirst(3)))
                                    .font(.system(size: 96))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Image(step.image)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color(.separator), lineWidth: 0.5))
                            }
                        }
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

            if let windowName {
                Text("置いたウィジェットを長押しし、「ウィジェットを編集」の「表示する写真」で「\(windowName)」を選びます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("official-window-widget-source")
            } else if !hasCats {
                Text("猫を登録すると、猫ごとにも選べます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { UsageCounter.shared.count(.widgetGuideOpened) }  // Usage (11/7)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let closeTitle {
                    Button(action: onComplete) {
                        Text(closeTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("widget-placement-close")
                } else {
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
