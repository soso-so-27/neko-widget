"""Exercise the production save lifetime without constructing the entire app."""
from pathlib import Path
import sys

source = Path('NekoWidget/Services/AppRecordPersistence.swift').read_text(encoding='utf-8')
start = source.index('@MainActor\nfinal class AppRecordSaveLifetime')
end = source.index('// UIKit adapter;', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end], encoding='utf-8')
