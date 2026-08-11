# Changelog

## 1.5.8 — 2026-08-11

- **Span dense folders (manifest overflow)**
  - Fixed span failing with “Not enough free space for span manifest” on discs packed with many small files
  - Planner reserves space for each part’s JSON (paths + fields), not only a fixed 16 KB headroom
  - Example: `fractorama` (~500 files, multi‑MB exe) spans and restores cleanly on 1.44 MB media

## 1.5.7 — 2026-08-11

- **Layout repair is opt-in only**
  - Removed automatic flattened-path repair on open and extract
  - Heuristic (`Folder-name` next to dir `Folder` → `Folder/name`) can mis-handle legitimate names like `Reports-summary.txt`
  - **Repair Layout…** in the drive toolbar (confirm dialog; Save to persist)
  - CLI `--repair-layout` still rewrites a disc file on request
  - Open no longer marks a disc dirty solely because two names match the pattern

## 1.5.6 — 2026-08-11

- **Span complete dialog**
  - Long disc lists are truncated (first few names, “… and N more …”, last disc)
  - Large multi-disc spans no longer produce a floor-to-ceiling alert

## 1.5.5 — 2026-08-11

- **Compress setting + false dirty on open**
  - Load FLOP/2 `compressOnWrite` from the disc header (and any zlib’d files), not always “on”
  - Label / packaging / compress toggles only mark dirty when the value actually changes
  - Opening an uncompressed disc no longer shows Compress checked or prompts Save on Eject without edits

## 1.5.4 — 2026-08-11

- **Folder import / extract layout**
  - Fixed `Volume.join` flattening nested paths (`Film Hiss/file` no longer becomes `Film Hiss-file`)
  - Extract preserves directory trees under the chosen destination
  - **Repair flattened layout**: on open/extract, files named `Folder-name` next to dir `Folder` move to `Folder/name`
  - CLI: `--repair-layout FILE.Floppy` rewrites the disc with corrected paths
  - Status notes when a disc was auto-repaired (Save to keep)

## 1.5.3 — 2026-08-10

- **Span disc UI**
  - Browser lists `/.diskette-span` again (manifest + chunks are real disc contents)
  - Left panel shows an **orange warning** on span discs: do not delete or rename `.diskette-span` or Restore Set will break
- Docs: README / FORMAT updated for span visibility and full feature set through 1.5.x

## 1.5.2 — 2026-08-10

- **Audit fixes** (features preserved)
  - Stop full-serialize on every sidebar redraw (was freezing selection/navigation)
  - Forward volume mutations to DriveSession so dirty badge / Save title stay correct
  - Confirm before New Disc replaces a mounted (especially dirty) disc
  - Prompt on **quit** if the disc is dirty (Save / Don’t Save / Cancel)
  - Sanitize path components (no `/` in names); validate FLP2 path length before save
  - Prevent renaming a folder into its own descendant
  - **Zip-slip guard** on extract/unspan (paths must stay under the destination)
  - Reliable window drops via drag pasteboard (not deferred item-provider loads)
  - Restore Set: detect folders with `isDirectory`, not `hasDirectoryPath`
  - Multi-delete: deepest-first; ignore already-removed children
  - Context menu extract/delete use menu selection set
  - Compact span manifests; CRC streaming empty-buffer seed fix
  - Folder pickers for Extract use `.folder` content type
  - CLI: bare `.Floppy` paths open in the GUI; temp cleanup on quit
  - Drag-out remains on the ⋮⋮ handle only (row click selects)

## 1.5.1 — 2026-08-10

- **Drag and drop**
  - Window-wide drop target with highlight: open `.Floppy`, or add files/folders to the mounted disc
  - Multi-file drops from Finder
  - **Drag out** browser rows to Finder (selection exports multiple items as a folder)
  - Security-scoped access for dropped URLs

## 1.5.0 — 2026-08-10

- **Streaming span / restore** (size-independent memory for multi‑GB sources)
  - Plan from sizes + streamed file CRC; read each chunk via `FileHandle` slice
  - Restore writes to a temp file incrementally, verifies length + CRC, then moves into place
  - Volume cache keeps at most one disc loaded while reassembling
- **Empty directories** preserved in the span set and recreated on restore
- **Hidden files skipped** (documented in UI, README, FORMAT)
- Restore **collision policy**: fail (default) / overwrite / skip — UI prompt; CLI `--force` / `--skip-existing`
- Failed span **deletes partial** numbered discs from the output folder
- Stricter set validation: matching root, media, label, totals; **reject duplicate disc indices**
- Part sort: by `partIndex`, then `byteOffset`

## 1.4.0 — 2026-08-10

- **Multi-disc span phase 2 — file chunking**
  - Files larger than one disc are split into parts across discs
  - Chunks stored under `/.diskette-span/parts/…`; whole files still at normal paths
  - Manifest **DISKETTE-SPAN/2** with per-part offsets, sizes, part CRC + full-file CRC
  - **Restore** reassembles chunks in order and verifies CRCs
  - Still reads **DISKETTE-SPAN/1** (whole-file) sets
  - CLI/UI report how many files were chunked / rejoined

## 1.3.0 — 2026-08-10

- **Multi-disc span (phase 1 — whole files)**
  - **Span Folder…** packs a host folder across as many `.Floppy` discs as needed
  - Sequential fill by path order; each disc is a normal volume + `/.diskette-span/manifest.json`
  - **Restore Set…** merges a complete set back to a folder
  - CLI: `--span`, `--unspan`, `--unspan-dir`; `--info` shows span metadata
  - Single files larger than one disc were rejected until 1.4.0

## 1.2.2 — 2026-08-10

- **Fix flaky file selection** in the drive browser
  - Replaced `Table` + cell `onTapGesture` (stole clicks from row selection) with a selection-bound **`List`**
  - Open uses list `primaryAction` (double-click / Return), not cell gestures
  - Prune stale selection after add/delete/rename; reset selection when changing folders

## 1.2.1 — 2026-08-10

- **Fix data-loss risk**: Save & Eject / Save-before-open only proceed after a successful save
  - `saveDisc` / `saveDiscAs` return `saved | cancelled | failed`
  - Cancelled Save panel or write failure leaves the current disc mounted
- **Verify `volume_crc`** on FLOP/2 load (and FLOP/1 when header present)
- Stricter FLP2 parser: unknown kinds/flags, duplicate paths, root path, trailing bytes, dirty directory records, file-under-file

## 1.2.0 — 2026-08-10

- **FLOP/2 binary packaging** (default): raw file payloads — no base64 ~33% tax
- **Optional zlib** per file when smaller than raw (binary only)
- Still **reads FLOP/1 text**; Save upgrades to binary by default
- UI: packaging picker, compress toggle, on-disk size / overhead estimate
- CLI: `--format binary|text`, `--no-compress`, `--repack`
- `--info` shows on-disk size and binary vs text estimates

## 1.1.0 — 2026-08-10

- **Open files from the disc** — double-click / Open writes a temp snapshot and launches the default macOS app (`NSWorkspace`)
- **Quick Look** — toolbar eye and context menu use system `QLPreviewPanel`
- Truncated in-app **Peek Text…** (≤12 lines / 480 characters); full file via Open or Extract
- Staging copies are read-only; cleaned up on **Eject**
- Docs: README usage, FORMAT design notes for open / Quick Look

## 1.0.0 — 2026-08-10

- Initial release: virtual floppy containers (FLOP/1, `.Floppy`)
- Classic media: 360 KB, 720 KB, 1.2 MB, 1.44 MB, 2.88 MB
- In-app drive: open containers, browse folders, add/extract/delete/rename
- 3.5″ / 5.25″ disc visual with capacity meter
- CRC-32 per file; capacity enforcement
- CLI: `--create`, `--list`, `--add`, `--extract`, `--info`, `--self-test`
- Double-click `.Floppy` opens in Diskette
