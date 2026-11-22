import SwiftUI

/// A compact handoff from the app to the user-controlled Home Screen flow.
/// iOS doesn't expose an API for placing a Home Screen widget, so the guide
/// shows only the three actions the user needs and lets the owner recheck the
/// installed configuration when the app becomes active again.
struct WidgetPlacementGuideView: View {
    /// Only the 設定 / まど guide's close button calls this (11/22: the first
    /// run's guide has 「つぎへ」 and then waits; it ends with 「あとで」 or
    /// 「置けました」).
    let onComplete: () -> Void
    let onSkip: () -> Void
    /// Opened again from 設定: one button with this title (it calls
    /// `onComplete`) in place of 「完了」 and 「あとで」 (11/7).
    var closeTitle: String? = nil
    /// An official window just received: the last line says to choose it in
    /// the Widget (11/7: one guide for every place, not a second one).
    var windowName: String? = nil
    @State private var page = 0

    /// One picture per step: the iOS screens the person will see, in order.
    /// 11/7: the clouded window and its tag are the last step (it was a small
    /// grey note under the pages). 11/12: every step is a drawn Home Screen
    /// (the screenshots showed a test app, a keyboard and a black wallpaper).
    private var steps: [(image: String, text: String)] {
        let cloudy: [(image: String, text: String)] = windowName == nil
            ? [(image: "onboarding-widget-cloudy", text: OnboardingPresentationCopy.widgetCloudyStep)] : []
        // 11/12: from 設定, the last step says how to change what it shows.
        let changeSource: [(image: String, text: String)] = closeTitle != nil && windowName == nil
            ? [(image: "onboarding-widget-change-source", text: OnboardingPresentationCopy.widgetChangeSourceStep)] : []
        return placementSteps + cloudy + changeSource
    }

    private var placementSteps: [(image: String, text: String)] {
        if #available(iOS 18.0, *) {
            Array(zip(["onboarding-widget-step-1", "onboarding-widget-step-2-ios18", "onboarding-widget-step-3"],
                      OnboardingPresentationCopy.widgetModernPlacementSteps))
        } else {
            // iOS 17's own 「＋」, and the search screen for the last step
            // (11/6: the pictures were one step off).
            Array(zip(["onboarding-widget-step-1", "onboarding-widget-step-2-legacy", "onboarding-widget-step-3"],
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
                    VStack(spacing: 14) {
                        Image(step.image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // Room for the page dots under the step's last line (11/12:
                    // they touched it).
                    .padding(.bottom, 56)
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
                    .buttonStyle(GuideSecondaryButtonStyle())
                    .accessibilityIdentifier("widget-placement-close")
                } else if page < steps.count - 1 {
                    // 11/22: 「つぎへ」 walks through every step. The button
                    // that seemed to place the Widget ended the first run
                    // after step 1.
                    Button {
                        withAnimation { page += 1 }
                    } label: {
                        Text(OnboardingPresentationCopy.widgetNextAction)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("widget-placement-next")
                } else {
                    // The last step: nothing to press. Coming back with the
                    // Widget placed shows 「置けました」 (or closes the 写真
                    // tab's sheet) by itself.
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(OnboardingPresentationCopy.widgetWaitingText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("widget-placement-waiting")
                }

                if closeTitle == nil {
                    // 「あとで」 is quiet grey text on every first-run page (11/12).
                    // It is the only way out besides placing the Widget.
                    Button(OnboardingPresentationCopy.widgetLaterAction, action: onSkip)
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("widget-placement-skip")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // The page's own colour: `.bar` drew a second band with a line.
            .background(Color(.systemBackground))
        }
    }
}

/// A secondary button that still reads as a button on a black ground
/// (11/12: `.bordered` was a black pill on black in dark mode).
struct GuideSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(uiColor: .secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: NekoRadius.button, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: NekoRadius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
