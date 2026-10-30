"""Compile the real usage model/read method with an in-memory HTTP stand-in."""
from pathlib import Path
import sys

source = Path('NekoWidget/Services/ManagedPreservationClient.swift').read_text(encoding='utf-8')
model = source[source.index('struct ManagedPreservationUsage:'):source.index('/// Read existing host-only identity.')]
start = source.index('    func usage() async throws -> ManagedPreservationUsage {')
method = source[start:source.index('\n    }', start) + 6]
checks = Path('NekoWidget/Services/SharingRuntimeSelfTest.swift').read_text(encoding='utf-8')
start = checks.index('    static func testManagedPreservationUsageBoundary()')
check = checks[start:checks.index('\n    }', start) + 6]
Path(sys.argv[1]).write_text('import Foundation\n' + model
    + '\nextension UsageTransportFixture {\n' + method + '\n}\n'
    + '\nextension ProductQuotaVerifier {\n' + check + '\n}\n', encoding='utf-8')
