# DigUp

Parts of WorkScribe's search engine are ported from DigUp (MIT, © 2026 Abdur Rahim), commit `f9b8106`.
The full license is in `LICENSE` next to this file. Ported files say so in a header comment:

- `Sources/WorkScribeCore/Search/SQLite.swift` — the SQLite wrapper (`Database.swift`).
- `Sources/WorkScribeCore/Search/SearchText.swift` — query terms, FTS5 patterns, normalization, snippets
  (`SearchText.swift`, `Searcher.terms/patterns/isLookup`).
- `Sources/WorkScribeCore/Search/Ranking.swift` — per-query z-scored meaning, modality centring, the
  coverage-bonus fusion and its constants, `strongCount` (`Searcher.swift`).
- `Sources/WorkScribeCore/Search/FolderRules.swift` and `TextChunker` — file classification, skipped
  folders and secret files, document chunking, HTML stripping (`Rules.swift`, `Extractors.swift`).
- `Sources/WorkScribe/FileExtractors.swift` — PDFKit pages, Cocoa rich text, AVFoundation 16 kHz windows that
  skip silence (`Extractors+Apple.swift`, `Media+Apple.swift`).
