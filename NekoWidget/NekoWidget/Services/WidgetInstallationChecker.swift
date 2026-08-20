import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetInstallationChecker: ObservableObject {
    static let widgetKind = "NekoWidget"

    @Published private(set) var state: WidgetInstallationState = .unknown

    private var requestIdentifier = UUID()

    var isInstalled: Bool {
        state == .installed
    }

    /// Home shows the recovery card only after WidgetKit confirms absence.
    /// Settings always keeps the placement guide available.
    var shouldOfferPlacementGuide: Bool {
        state.shouldOfferPlacementGuide
    }

    /// Starts a non-blocking WidgetKit lookup.
    ///
    /// The completion and skip buttons in `WidgetPlacementGuideView` do not
    /// depend on this request. If WidgetKit cannot answer, the state becomes
    /// `unavailable` and the user can continue normally.
    func refresh() {
        let requestIdentifier = UUID()
        self.requestIdentifier = requestIdentifier
        if state == .unknown || state == .unavailable {
            state = .checking
        }

        let expectedKind = Self.widgetKind
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let resolvedState: WidgetInstallationState
            switch result {
            case let .success(configurations):
                resolvedState = configurations.contains { configuration in
                    configuration.kind == expectedKind
                } ? .installed : .notInstalled
            case .failure:
                resolvedState = .unavailable
            }

            Task { @MainActor [weak self] in
                guard let self, self.requestIdentifier == requestIdentifier else {
                    return
                }
                self.state = resolvedState
            }
        }
    }
}
