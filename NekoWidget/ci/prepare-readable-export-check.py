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
head_start = app.index('struct AppRecordHead:')
# Stop at the model's own top-level closing brace, not the next UI declaration.
# Lifecycle helpers between these declarations are not export dependencies.
models += app[head_start:app.index('\n}\n', head_start) + len('\n}\n')]
models += '\nenum ToolBackupFiles {\n'
for signature in ['    static func protect(', '    static func write(', '    static func read(']:
    start = tools.index(signature, tools.index('enum ToolBackupFiles'))
    end = tools.index('\n    }', start) + len('\n    }')
    models += tools[start:end] + '\n'
models += '}\n'
Path(sys.argv[1]).write_text('import Foundation\nimport CryptoKit\n' + models, encoding='utf-8')
