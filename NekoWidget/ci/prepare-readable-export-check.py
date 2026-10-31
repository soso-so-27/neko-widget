"""Compile the actual export/graph code without UIKit or live services.

Only filesystem helpers and model declarations are sliced from production.
Schema validation is supplied explicitly by the synthetic test; the app passes
ToolBackupValidation.validate. This test does not claim an iPhone restoration.
"""
from pathlib import Path
import sys

services = Path('NekoWidget/Services')
client = (services / 'ManagedPreservationClient.swift').read_text(encoding='utf-8')
tools = (services / 'ToolPreservation.swift').read_text(encoding='utf-8')
app = (services / 'AppRecordPersistence.swift').read_text(encoding='utf-8')
models = client[client.index('enum ManagedPreservationError:'):client.index('struct ManagedPreservationChallenge:')]
models += tools[tools.index('struct ToolBackupPart:'):tools.index('enum ToolBackupTreeReceipts')]
models += app[app.index('struct AppRecordHead:'):app.index('@MainActor\nfinal class AppRecordPersistence')]
models += '\nenum ToolBackupFiles {\n'
for signature in ['    static func protect(', '    static func write(', '    static func read(']:
    start = tools.index(signature, tools.index('enum ToolBackupFiles'))
    end = tools.index('\n    }', start) + len('\n    }')
    models += tools[start:end] + '\n'
models += '}\n'
Path(sys.argv[1]).write_text('import Foundation\nimport CryptoKit\n' + models, encoding='utf-8')
