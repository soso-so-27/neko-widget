import SwiftUI
import UIKit

/// The product-critical fourth onboarding page. The same view is also suitable
/// for presentation from Settings after onboarding has been skipped.
struct WidgetPlacementGuideView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedStep = 0

    init(
        onComplete: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    private var steps: [OnboardingWidgetGuideStepPresentation] {
        OnboardingWidgetGuideStepPresentation.all
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(OnboardingPresentationCopy.widgetTitleLines.joined(separator: "\n"))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)

                TabView(selection: $selectedStep) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        WidgetPlacementStepPanel(step: step)
                            .padding(.horizontal, 4)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: pagerHeight)
                .accessibilityValue("手順 \(selectedStep + 1) / \(steps.count)")

                pagePicker

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
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("widget-placement-skip")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
    }

    private var pagerHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 570 : 440
    }

    private var pagePicker: some View {
        HStack(spacing: 12) {
            ForEach(steps.indices, id: \.self) { index in
                Button {
                    selectStep(index)
                } label: {
                    Circle()
                        .fill(index == selectedStep ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: index == selectedStep ? 11 : 8, height: index == selectedStep ? 11 : 8)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("手順 \(index + 1)")
                .accessibilityValue(index == selectedStep ? "選択中" : "")
                .accessibilityAddTraits(index == selectedStep ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func selectStep(_ index: Int) {
        guard steps.indices.contains(index) else { return }
        if reduceMotion {
            selectedStep = index
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                selectedStep = index
            }
        }
    }
}

private enum WidgetPlacementIllustration {
    case holdHomeScreen
    case addControl(isModern: Bool)
    case search
    case chooseSize
}

private struct WidgetPlacementStepPanel: View {
    let step: OnboardingWidgetGuideStepPresentation

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                illustration
                    .padding(12)

                GuideArrow(start: arrowPoints.start, end: arrowPoints.end)
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityHidden(true)

            Text(caption)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 32))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("手順 \(step.id)。\(caption)")
    }

    @ViewBuilder
    private var illustration: some View {
        if let image = screenshotAsset {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            WidgetPlacementFallbackIllustration(kind: illustrationKind)
        }
    }

    /// The original four-name asset contract represents the iOS 17 flow. On
    /// iOS 18 and later, Apple moved Widget addition under 編集, so only the
    /// explicit modern variant may replace the accurate SwiftUI fallback.
    /// https://support.apple.com/ja-jp/guide/iphone/iphb8f1bf206/ios
    private var screenshotAsset: UIImage? {
        if step.id == 2 {
            if #available(iOS 18.0, *) {
                return UIImage(named: "onboarding-widget-step-2-ios18")
            }
        }
        return UIImage(named: step.imageAssetName)
    }

    private var caption: String {
        if step.id == 2 {
            if #available(iOS 18.0, *) {
                return "左上の「編集」→「ウィジェットを追加」"
            }
        }
        return step.caption
    }

    private var illustrationKind: WidgetPlacementIllustration {
        switch step.id {
        case 1:
            return .holdHomeScreen
        case 2:
            if #available(iOS 18.0, *) {
                return .addControl(isModern: true)
            }
            return .addControl(isModern: false)
        case 3:
            return .search
        default:
            return .chooseSize
        }
    }

    private var arrowPoints: (start: UnitPoint, end: UnitPoint) {
        switch step.id {
        case 1:
            return (UnitPoint(x: 0.78, y: 0.24), UnitPoint(x: 0.57, y: 0.42))
        case 2:
            return (UnitPoint(x: 0.65, y: 0.26), UnitPoint(x: 0.22, y: 0.14))
        case 3:
            return (UnitPoint(x: 0.78, y: 0.36), UnitPoint(x: 0.50, y: 0.23))
        default:
            return (UnitPoint(x: 0.76, y: 0.64), UnitPoint(x: 0.50, y: 0.79))
        }
    }
}

private struct GuideArrow: Shape {
    let start: UnitPoint
    let end: UnitPoint

    func path(in rect: CGRect) -> Path {
        let startPoint = CGPoint(
            x: rect.minX + (rect.width * start.x),
            y: rect.minY + (rect.height * start.y)
        )
        let endPoint = CGPoint(
            x: rect.minX + (rect.width * end.x),
            y: rect.minY + (rect.height * end.y)
        )
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let arrowLength = min(rect.width, rect.height) * 0.055
        let wingAngle = CGFloat.pi / 5

        var path = Path()
        path.move(to: startPoint)
        path.addLine(to: endPoint)
        path.move(to: endPoint)
        path.addLine(to: CGPoint(
            x: endPoint.x - (arrowLength * cos(angle - wingAngle)),
            y: endPoint.y - (arrowLength * sin(angle - wingAngle))
        ))
        path.move(to: endPoint)
        path.addLine(to: CGPoint(
            x: endPoint.x - (arrowLength * cos(angle + wingAngle)),
            y: endPoint.y - (arrowLength * sin(angle + wingAngle))
        ))
        return path
    }
}

private struct WidgetPlacementFallbackIllustration: View {
    let kind: WidgetPlacementIllustration

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.indigo.opacity(0.72), Color.blue.opacity(0.40), Color.pink.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            switch kind {
            case .holdHomeScreen:
                mockHomeScreen
                VStack {
                    Spacer()
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(.bottom, 66)
                }
            case let .addControl(isModern):
                mockHomeScreen
                if isModern {
                    modernEditMenu
                } else {
                    legacyAddButton
                }
            case .search:
                widgetSearch
            case .chooseSize:
                widgetSizePicker
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
    }

    private var mockHomeScreen: some View {
        VStack(spacing: 14) {
            HStack {
                Text("9:41")
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.caption.bold())
            .foregroundStyle(.white)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 18) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(iconColor(index))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: iconName(index))
                                .foregroundStyle(.white)
                        }
                }
            }

            Spacer()

            HStack(spacing: 18) {
                ForEach(["phone.fill", "safari.fill", "message.fill", "music.note"], id: \.self) { icon in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.26))
                        .frame(width: 43, height: 43)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundStyle(.white)
                        }
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(20)
    }

    private var legacyAddButton: some View {
        VStack {
            HStack {
                Image(systemName: "plus")
                    .font(.headline.bold())
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                Spacer()
                Text("完了")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    private var modernEditMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("編集")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                Label("ウィジェットを追加", systemImage: "plus.square")
                Divider()
                Label("カスタマイズ", systemImage: "circle.lefthalf.filled")
            }
            .font(.caption.weight(.semibold))
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 190, alignment: .leading)

            Spacer()
        }
        .padding(14)
    }

    private var widgetSearch: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.32))
                .frame(width: 38, height: 5)

            Text("ウィジェットを追加")
                .font(.headline)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                Text("ねこのまど")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 13))

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "cat.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ねこのまど")
                        .font(.headline)
                    Text("毎日ちがう、うちの子")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(20)
        .background(.regularMaterial)
    }

    private var widgetSizePicker: some View {
        VStack(spacing: 14) {
            Text("ねこのまど")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 10) {
                widgetPreview(width: 58, height: 58)
                widgetPreview(width: 112, height: 58)
                widgetPreview(width: 82, height: 94)
            }

            HStack(spacing: 6) {
                Circle().fill(Color.primary).frame(width: 6, height: 6)
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            }

            Text("ウィジェットを追加")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))

            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(22)
        .background(.regularMaterial)
    }

    private func widgetPreview(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(
                LinearGradient(
                    colors: [Color.orange.opacity(0.82), Color.brown.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: height)
            .overlay {
                Image(systemName: "cat.fill")
                    .foregroundStyle(.white)
            }
    }

    private func iconColor(_ index: Int) -> Color {
        [Color.blue, .orange, .pink, .green, .purple, .cyan][index % 6].opacity(0.82)
    }

    private func iconName(_ index: Int) -> String {
        [
            "photo.fill", "calendar", "camera.fill", "map.fill",
            "envelope.fill", "clock.fill", "heart.fill", "cloud.sun.fill",
            "book.fill", "cart.fill", "gearshape.fill", "pawprint.fill"
        ][index % 12]
    }
}
