import CryptoKit
import CoreGraphics
import Foundation

enum DailySharingProtocol {
    static let version = 1
    static let maximumSlotCount = 20
    static let maximumCanonicalPixelDimension = 2_048
    static let maximumMediaCiphertextBytes = 300 * 1_024
    static let maximumManifestCiphertextBytes = 64 * 1_024
    static let chachaCombinedOverheadBytes = 12 + 16
    static let maximumJPEGBytes = maximumMediaCiphertextBytes - chachaCombinedOverheadBytes
    static let coordinateScale = 1_000_000
    static let rendererVersion = WidgetRenderPlanner.rendererVersion
}

enum DailySharingError: LocalizedError, Equatable {
    case featureDisabled
    case notPaired
    case invalidLocalManifest
    case localPhotoUnavailable
    case degradedPhoto
    case insufficientPhotoResolution
    case canonicalEncodingFailed
    case invalidSharedManifest
    case invalidCiphertext
    case responseTooLarge
    case retryableServer(retryAfterSeconds: Int?)
    case waitingForReconciliation
    case stateUnavailable
    case stateChanged

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return "このビルドでは写真の共有が有効になっていません。"
        case .notPaired:
            return "写真を共有するには、先にペアリングを完了してください。"
        case .invalidLocalManifest:
            return "今日のウィジェット写真を安全に固定できませんでした。"
        case .localPhotoUnavailable:
            return "端末内にある写真だけでは今日の共有画像を作れませんでした。"
        case .degradedPhoto:
            return "低品質の一時画像しか取得できなかったため、昨日の写真を維持します。"
        case .insufficientPhotoResolution:
            return "表示に必要な画質を保てないため、昨日の写真を維持します。"
        case .canonicalEncodingFailed:
            return "共有用の小さい画像を作れませんでした。"
        case .invalidSharedManifest, .invalidCiphertext:
            return "相手から届いた共有データを確認できませんでした。"
        case .responseTooLarge:
            return "共有サーバーから想定より大きな応答が届きました。"
        case .retryableServer:
            return "共有サーバーが一時的に混み合っています。保存済みの続きから再試行します。"
        case .waitingForReconciliation:
            return "共有世代の期限を確認してから安全に再開します。"
        case .stateUnavailable:
            return "写真共有の状態を読み込めませんでした。"
        case .stateChanged:
            return "別の共有更新が先に完了したため、最新の状態から再開します。"
        }
    }
}

/// Network-safe fixed-point normalized geometry. Local Widget manifests keep
/// using `Double`; only this quantized representation crosses devices.
struct SharingNormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(_ local: WidgetRenderRect) {
        let integerScale = DailySharingProtocol.coordinateScale
        let scale = Double(integerScale)
        func quantizedEndpoint(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            let clamped = min(1, max(0, value))
            return min(integerScale, max(0, Int((clamped * scale).rounded())))
        }

        // Quantize the two endpoints, not origin and extent independently.
        // Otherwise two individually rounded values can sum to scale + 1 for
        // a valid edge-clamped crop (for example 0.0546875 + 0.9453125).
        let minX = quantizedEndpoint(local.x)
        let minY = quantizedEndpoint(local.y)
        let maxX = quantizedEndpoint(local.x + local.width)
        let maxY = quantizedEndpoint(local.y + local.height)
        x = minX
        y = minY
        width = maxX - minX
        height = maxY - minY
    }

    var localRect: WidgetRenderRect {
        let scale = Double(DailySharingProtocol.coordinateScale)
        return WidgetRenderRect(
            CGRect(
                x: Double(x) / scale,
                y: Double(y) / scale,
                width: Double(width) / scale,
                height: Double(height) / scale
            )
        )
    }

    var isValid: Bool {
        let scale = DailySharingProtocol.coordinateScale
        return x >= 0 && y >= 0 && width > 0 && height > 0
            && x <= scale && y <= scale && width <= scale && height <= scale
            && x + width <= scale && y + height <= scale
    }

    static let fullSource = SharingNormalizedRect(.fullSource)
}

struct SharingFamilyRenderPlan: Codable, Equatable, Hashable, Sendable {
    var sourceRect: SharingNormalizedRect
    var compositionMode: WidgetCompositionMode

    init(_ local: WidgetFamilyRenderPlan) {
        sourceRect = SharingNormalizedRect(local.sourceRect)
        compositionMode = local.compositionMode
    }
}

struct SharingRenderPlans: Codable, Equatable, Hashable, Sendable {
    var small: SharingFamilyRenderPlan
    var medium: SharingFamilyRenderPlan
    var large: SharingFamilyRenderPlan

    init(_ local: WidgetRenderPlans) {
        small = SharingFamilyRenderPlan(local.small)
        medium = SharingFamilyRenderPlan(local.medium)
        large = SharingFamilyRenderPlan(local.large)
    }

    func plan(for variant: WidgetImageVariant) -> SharingFamilyRenderPlan {
        switch variant {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var localPlans: WidgetRenderPlans {
        func local(_ value: SharingFamilyRenderPlan) -> WidgetFamilyRenderPlan {
            WidgetFamilyRenderPlan(
                sourceRect: value.sourceRect.localRect,
                compositionMode: value.compositionMode
            )
        }
        return WidgetRenderPlans(
            small: local(small),
            medium: local(medium),
            large: local(large)
        )
    }

    func validated(sourcePixelSize: WidgetSourcePixelSize) throws -> Self {
        guard sourcePixelSize.isValid,
              sourcePixelSize.width <= DailySharingProtocol.maximumCanonicalPixelDimension,
              sourcePixelSize.height <= DailySharingProtocol.maximumCanonicalPixelDimension
        else { throw DailySharingError.invalidSharedManifest }

        for variant in WidgetImageVariant.allCases {
            let value = plan(for: variant)
            guard value.sourceRect.isValid else {
                throw DailySharingError.invalidSharedManifest
            }
            switch value.compositionMode {
            case .mediumUpperFocus:
                guard variant == .medium else {
                    throw DailySharingError.invalidSharedManifest
                }
            case .blurredFitFallback:
                guard value.sourceRect == .fullSource else {
                    throw DailySharingError.invalidSharedManifest
                }
                continue
            case .catFullBleed:
                break
            }

            let rect = value.sourceRect.localRect
            let cropWidth = rect.width * Double(sourcePixelSize.width)
            let cropHeight = rect.height * Double(sourcePixelSize.height)
            guard cropWidth > 0, cropHeight > 0 else {
                throw DailySharingError.invalidSharedManifest
            }
            let expected = Double(variant.pixelWidth) / Double(variant.pixelHeight)
            let relativeError = abs(cropWidth / cropHeight - expected) / expected
            // Fixed-point quantization plus source-pixel alignment is bounded
            // to a small rendering-only tolerance.
            guard relativeError <= 0.003 else {
                throw DailySharingError.invalidSharedManifest
            }
        }
        return self
    }
}

/// Metadata authenticated both by the encrypted manifest and the media AAD.
/// It deliberately contains no PhotoKit identifier, date, bounding box, or
/// analysis fingerprint.
struct SharingMediaBinding: Codable, Equatable, Hashable, Sendable {
    var rendererVersion: String
    var canonicalPixelSize: WidgetSourcePixelSize
    var renderPlans: SharingRenderPlans

    init(canonicalPixelSize: WidgetSourcePixelSize, renderPlans: WidgetRenderPlans) {
        rendererVersion = DailySharingProtocol.rendererVersion
        self.canonicalPixelSize = canonicalPixelSize
        self.renderPlans = SharingRenderPlans(renderPlans)
    }

    func validated() throws -> Self {
        guard rendererVersion == DailySharingProtocol.rendererVersion else {
            throw DailySharingError.invalidSharedManifest
        }
        _ = try renderPlans.validated(sourcePixelSize: canonicalPixelSize)
        return self
    }

    func canonicalData() throws -> Data {
        _ = try validated()
        var fields = [
            "NW1.MEDIA-BINDING",
            String(DailySharingProtocol.version),
            rendererVersion,
            String(DailySharingProtocol.coordinateScale),
            String(canonicalPixelSize.width),
            String(canonicalPixelSize.height)
        ]
        for variant in WidgetImageVariant.allCases {
            let plan = renderPlans.plan(for: variant)
            fields.append(contentsOf: [
                variant.rawValue,
                plan.compositionMode.rawValue,
                String(plan.sourceRect.x),
                String(plan.sourceRect.y),
                String(plan.sourceRect.width),
                String(plan.sourceRect.height)
            ])
        }
        return try PairingCanonicalEncoder.encode(fields)
    }

    func bindingHash() throws -> Data {
        PairingCrypto.sha256(try canonicalData())
    }
}

struct DailySharedManifestMedia: Codable, Equatable, Sendable {
    var mediaID: String
    var binding: SharingMediaBinding
    var ciphertextSize: Int
    var ciphertextSHA256: String
    var canonicalJPEGPlaintextSHA256: String
}

/// The only plaintext structure encrypted as the shared generation manifest.
/// Slot order can repeat a media ID; the media table remains unique and sorted.
struct DailySharedManifest: Codable, Equatable, Sendable {
    var protocolVersion: Int = DailySharingProtocol.version
    var media: [DailySharedManifestMedia]
    var slots: [String]

    func validated() throws -> Self {
        guard protocolVersion == DailySharingProtocol.version,
              !media.isEmpty,
              media.count <= DailySharingProtocol.maximumSlotCount,
              !slots.isEmpty,
              slots.count <= DailySharingProtocol.maximumSlotCount
        else { throw DailySharingError.invalidSharedManifest }

        let identifiers = media.map(\.mediaID)
        guard identifiers == identifiers.sorted(),
              Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy(PairingValidation.isOpaqueIdentifier),
              Set(slots) == Set(identifiers)
        else { throw DailySharingError.invalidSharedManifest }
        for value in media {
            _ = try value.binding.validated()
            guard (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumMediaCiphertextBytes)
                .contains(value.ciphertextSize),
                  Data(base64URLString: value.ciphertextSHA256)?.count == 32,
                  Data(base64URLString: value.canonicalJPEGPlaintextSHA256)?.count == 32
            else { throw DailySharingError.invalidSharedManifest }
        }
        return self
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as DailySharingError {
            throw error
        } catch {
            throw DailySharingError.invalidSharedManifest
        }
    }
}

enum DailySharingCrypto {
    static func mediaAAD(
        spaceID: String,
        sourceID: String,
        publisherMemberID: String,
        generationID: String,
        shareDayKey: Int,
        mediaID: String,
        mediaBindingHash: Data
    ) throws -> Data {
        guard [spaceID, sourceID, publisherMemberID, generationID, mediaID]
            .allSatisfy(PairingValidation.isOpaqueIdentifier),
              (0...10_000_000).contains(shareDayKey),
              mediaBindingHash.count == 32
        else { throw DailySharingError.invalidCiphertext }
        return try PairingCanonicalEncoder.encode([
            "NW1.SHARED-MEDIA",
            String(DailySharingProtocol.version),
            spaceID,
            sourceID,
            publisherMemberID,
            generationID,
            String(shareDayKey),
            mediaID,
            mediaBindingHash.base64URLEncodedString()
        ])
    }

    static func manifestAAD(
        spaceID: String,
        sourceID: String,
        publisherMemberID: String,
        generationID: String,
        shareDayKey: Int,
        prepareAttemptID: String,
        prepareAttemptRevision: Int,
        reservedRevision: Int,
        rotationAnchorUTC: Int,
        itemCount: Int
    ) throws -> Data {
        guard [spaceID, sourceID, publisherMemberID, generationID]
            .allSatisfy(PairingValidation.isOpaqueIdentifier),
              PairingValidation.isOpaqueIdentifier(prepareAttemptID),
              (0...10_000_000).contains(shareDayKey),
              prepareAttemptRevision > 0,
              reservedRevision > 0,
              rotationAnchorUTC > 0,
              (1...DailySharingProtocol.maximumSlotCount).contains(itemCount)
        else { throw DailySharingError.invalidCiphertext }
        return try PairingCanonicalEncoder.encode([
            "NW1.SHARED-MANIFEST",
            String(DailySharingProtocol.version),
            spaceID,
            sourceID,
            publisherMemberID,
            generationID,
            String(shareDayKey),
            prepareAttemptID,
            String(prepareAttemptRevision),
            String(reservedRevision),
            String(rotationAnchorUTC),
            String(itemCount)
        ])
    }

    static func sealMedia(_ jpeg: Data, roomKey: Data, aad: Data) throws -> Data {
        guard !jpeg.isEmpty, jpeg.count <= DailySharingProtocol.maximumJPEGBytes else {
            throw DailySharingError.canonicalEncodingFailed
        }
        let sealed = try seal(jpeg, roomKey: roomKey, aad: aad, domain: "NW1.MEDIA.KEY")
        guard sealed.count <= DailySharingProtocol.maximumMediaCiphertextBytes else {
            throw DailySharingError.canonicalEncodingFailed
        }
        return sealed
    }

    static func openMedia(_ ciphertext: Data, roomKey: Data, aad: Data) throws -> Data {
        guard ciphertext.count >= DailySharingProtocol.chachaCombinedOverheadBytes + 1,
              ciphertext.count <= DailySharingProtocol.maximumMediaCiphertextBytes
        else { throw DailySharingError.invalidCiphertext }
        return try open(ciphertext, roomKey: roomKey, aad: aad, domain: "NW1.MEDIA.KEY")
    }

    static func sealManifest(_ plaintext: Data, roomKey: Data, aad: Data) throws -> Data {
        let sealed = try seal(plaintext, roomKey: roomKey, aad: aad, domain: "NW1.MANIFEST.KEY")
        guard sealed.count <= DailySharingProtocol.maximumManifestCiphertextBytes else {
            throw DailySharingError.invalidSharedManifest
        }
        return sealed
    }

    static func openManifest(_ ciphertext: Data, roomKey: Data, aad: Data) throws -> Data {
        guard ciphertext.count >= DailySharingProtocol.chachaCombinedOverheadBytes + 1,
              ciphertext.count <= DailySharingProtocol.maximumManifestCiphertextBytes
        else { throw DailySharingError.invalidCiphertext }
        return try open(ciphertext, roomKey: roomKey, aad: aad, domain: "NW1.MANIFEST.KEY")
    }

    private static func seal(
        _ plaintext: Data,
        roomKey: Data,
        aad: Data,
        domain: String
    ) throws -> Data {
        let key = try derivedKey(roomKey: roomKey, domain: domain, aad: aad)
        return try ChaChaPoly.seal(plaintext, using: key, authenticating: aad).combined
    }

    private static func open(
        _ ciphertext: Data,
        roomKey: Data,
        aad: Data,
        domain: String
    ) throws -> Data {
        do {
            let key = try derivedKey(roomKey: roomKey, domain: domain, aad: aad)
            return try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: ciphertext),
                using: key,
                authenticating: aad
            )
        } catch {
            throw DailySharingError.invalidCiphertext
        }
    }

    private static func derivedKey(
        roomKey: Data,
        domain: String,
        aad: Data
    ) throws -> SymmetricKey {
        guard roomKey.count == 32 else { throw PairingError.malformedCredential }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: roomKey),
            // Exact object context is part of key derivation as well as AEAD.
            // This prevents accidental key reuse across media, generations,
            // and manifest prepare attempts even with independent nonces.
            salt: PairingCrypto.sha256(aad),
            info: Data(domain.utf8),
            outputByteCount: 32
        )
    }
}
