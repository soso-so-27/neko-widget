from pathlib import Path
import sys
source=Path("NekoWidget/Services/ManagedPreservationCoordinator.swift").read_text()
start=source.index("enum PreservationOpeningCheck {")
end=source.index("/// Owns only this screen",start)
Path(sys.argv[1]).write_text("import Foundation\nenum ManagedPreservationError: Error { case unavailable, staleSession }\n"+source[start:end]+Path("ci/verify-preservation-opening.swift").read_text())
