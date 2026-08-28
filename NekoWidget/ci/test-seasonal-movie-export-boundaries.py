from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NekoWidget" / "Services" / "SeasonalMovieExportService.swift"
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
        'let endingDuration: TimeInterval = 1.8',
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
    assert "SeasonalMovieExportService.swift in Sources" in project
    assert project.count("SeasonalMovieExportService.swift in Sources") == 2
    soundtrack = SOUNDTRACK.read_bytes()
    assert soundtrack[:4] == b"RIFF"
    assert soundtrack[8:12] == b"WAVE"
    assert 1_000_000 <= len(soundtrack) <= 1_100_000


if __name__ == "__main__":
    main()
