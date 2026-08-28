import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NekoWidget" / "Services" / "SeasonalMovieExportService.swift"
PRESENTATION = ROOT / "NekoWidget" / "Views" / "SeasonalMoviePresentation.swift"
VIEW = ROOT / "NekoWidget" / "Views" / "SeasonalMovieView.swift"
PROJECT = ROOT / "NekoWidget.xcodeproj" / "project.pbxproj"
SOUNDTRACK = (
    ROOT
    / "NekoWidget"
    / "Assets.xcassets"
    / "SeasonalMovieAmbient.dataset"
    / "seasonal-movie-ambient.wav"
)


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    presentation = PRESENTATION.read_text(encoding="utf-8")
    view = VIEW.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    required = (
        "AVAssetWriter(outputURL: outputURL, fileType: .mp4)",
        "AVVideoCodecType.h264",
        "CGSize(width: 720, height: 1_280)",
        'private static let outputFileName = "seasonal-movie.mp4"',
        'private static let exportDirectoryName = "SeasonalMovieExports"',
        "options.isNetworkAccessAllowed = false",
        "writer.metadata = []",
        'NSDataAsset(name: "SeasonalMovieAmbient")',
        "AVAssetReaderAudioMixOutput",
        "AVMutableComposition()",
        "AVFormatIDKey: kAudioFormatMPEG4AAC",
        'case opening(title: String, period: String)',
        'case month(String)',
        'case ending',
        'let monthMarkerDuration: TimeInterval = 0.8',
        'parameters.setVolume(0, at: .zero)',
        'fromStartVolume: 0',
        'toEndVolume: SeasonalMovieSoundtrackContract.volume',
        'fromStartVolume: SeasonalMovieSoundtrackContract.volume',
        'AVSampleRateKey: SeasonalMovieSoundtrackContract.sampleRate',
        'AVNumberOfChannelsKey: SeasonalMovieSoundtrackContract.channelCount',
        'AVEncoderBitRateKey: SeasonalMovieSoundtrackContract.encoderBitRate',
        'localFrame < overlayVisibleFrameCount',
        '.dateTime.month(.wide)',
        "duration: Double(totalFrameCount) / Double(Self.frameRate)",
        "FileProtectionType.complete",
        "func cleanupExport(at outputURL: URL)",
        "func cleanupStaleExports(",
        "static func cleanupStaleExports(",
        "Self.cleanupExport(at: outputURL, fileManager: fileManager)",
    )
    for boundary in required:
        assert boundary in source, f"missing export boundary: {boundary}"

    forbidden = (
        "PHAssetChangeRequest",
        "PHAssetCreationRequest",
        "PHPhotoLibrary.shared().performChanges",
        "isNetworkAccessAllowed = true",
        "AVAssetExportSession",
    )
    for boundary in forbidden:
        assert boundary not in source, f"unexpected export behavior: {boundary}"

    assert "source audio are never copied" in source
    assert 'let text = "この季節も、ここまで" as NSString' in source
    assert "finalFrameImage = generatedImage" in source
    assert "sourceTrack" in source
    contract_boundaries = (
        "enum SeasonalMovieSoundtrackContract",
        "static let volume: Float = 0.55",
        "static let fadeInDuration: TimeInterval = 0.25",
        "static let endingHoldDuration: TimeInterval = 0.8",
        "static let fadeOutDuration: TimeInterval = 1.0",
        "static let endingDuration = endingHoldDuration + fadeOutDuration",
        "static let sampleRate = 48_000",
        "static let channelCount = 2",
        "static let encoderBitRate = 128_000",
    )
    for boundary in contract_boundaries:
        assert boundary in presentation, f"missing soundtrack contract: {boundary}"
    assert "SeasonalMovieSoundtrackContract.endingHoldDuration" in view
    assert "SeasonalMovieSoundtrackContract.fadeOutDuration" in view
    assert "SeasonalMovieSoundtrackContract.fadeInDuration" in view
    assert "SeasonalMovieExportService.swift in Sources" in project
    assert project.count("SeasonalMovieExportService.swift in Sources") == 2
    with wave.open(str(SOUNDTRACK), "rb") as soundtrack:
        assert soundtrack.getcomptype() == "NONE"
        assert soundtrack.getnchannels() == 2
        assert soundtrack.getframerate() == 48_000
        assert soundtrack.getsampwidth() == 2
        duration = soundtrack.getnframes() / soundtrack.getframerate()
        assert abs(duration - 24.0) <= (1 / soundtrack.getframerate())


if __name__ == "__main__":
    main()
