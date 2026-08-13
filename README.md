# Diskette

**Version 1.6.0** · macOS 13+

A native macOS app that stores data in **virtual floppy disc containers** (`.Floppy`). Containers **open inside the app** — browse, add, extract, and delete files without mounting an image in Finder. Large folders can be **spanned** across multiple discs with **chunking** and **streaming** I/O.

Same family of purpose as PaperTape, Phonograph, and Parchment: an obscure portable medium. This one is multi-file, capacity-limited like real floppies, and designed as a **drive UI**.

## Features

| Area | Capability |
|------|------------|
| Containers | `.Floppy` multi-file discs (FLOP/2 binary default · FLOP/1 text legacy) |
| Media | 360 KB · 720 KB · 1.2 MB · **1.44 MB** · 2.88 MB |
| In-app drive | Mount a disc; folder browser with multi-select |
| Folder trees | Import/export preserves nested folders |
| Layout repair | **Opt-in only** — Repair Layout… / `--repair-layout` (join-bug heuristic) |
| **Span** | Multi-disc sets; files that don’t fit are **chunked** |
| **Recovery discs** | Optional XOR (1 loss) or Reed–Solomon (up to N losses) |
| **Streaming** | Span/restore stream from disk — not all host files in RAM |
| Empty dirs | Preserved across span/restore |
| Hidden files | **Skipped** on span (`.skipsHiddenFiles`) |
| Restore collisions | Fail by default; overwrite / skip via UI or CLI |
| Open / Quick Look | Default app + system Quick Look (temp snapshots) |
| Drag & drop | Drop discs/files in; drag out via the **⋮⋮** handle |
| Integrity | Per-file CRC-32, span part/file CRC, volume CRC |
| CLI | create, list, add, extract, info, repack, repair-layout, span, unspan, self-test |

This is **packaging / storage**, not encryption.

### Browser & selection

- Click a row to select; ⌘-click for multi-select  
- Double-click opens a folder or the default app for a file  
- **Drag to Finder** only from the **⋮⋮** grip (keeps selection reliable)  
- Drop `.Floppy` to open; drop files/folders onto a mounted disc to add  

### Import / extract folders

- Adding a folder stores paths like `/Parent/Sub/file.txt`  
- **Extract** recreates that tree under the destination  
- Discs damaged by a short-lived join bug (`Film Hiss-file.txt` beside `Film Hiss/`) can be fixed with **Repair Layout…** or `--repair-layout` — **not** applied automatically (the pattern can match real names like `Reports-summary.txt`)  

### Span notes

- **Span Folder…** packs a host folder across as many discs as needed  
- Oversized files become chunks under `/.diskette-span/parts/`  
- Each span disc includes `/.diskette-span/manifest.json` (and parts when chunked)  
- Those paths **appear in the browser**; the **left panel warns** not to delete or rename `.diskette-span`  
- **Restore Set…** needs a complete set (all discs, same set id)  
- Host **hidden** (dot) files are not spanned  
- A failed span deletes any **partial** `*-NNofMM.Floppy` files it wrote  
- **Span complete** summary truncates long disc lists (first / last + count) so large sets stay on-screen  
- Span planner leaves room for a **large manifest** when a disc holds many small files (not just a fixed headroom)  
- Optional **recovery discs**: 1× XOR (any **one** loss) or N× Reed–Solomon (up to **N** losses); `*-Recovery-JJofNN.Floppy`  

### Packaging

| Format | Notes |
|--------|--------|
| **FLOP/2** (default) | Binary raw payloads + optional zlib |
| **FLOP/1** | Text + base64 (legacy; still opens; Save can upgrade) |

**Compress (zlib)** in the sidebar reflects how the mounted disc was last saved (FLOP/2 header flag). Opening an uncompressed disc leaves the toggle off and does not mark the disc dirty. Changing packaging or compress only prompts Save when you actually change them.

### Damage recovery (format notes)

- If the directory still loads, extract normally; **CRC-32** shows which files are intact.
- A broken header may still leave **uncompressed** payloads carvable by type signatures; **zlib** records need directory metadata for boundaries.
- Span restore needs intact manifests. Without recovery discs, a **missing disc** cannot be rebuilt.
- Optional **recovery discs** at span time: **1× XOR** (any one loss) or **N× Reed–Solomon** (up to N losses).
- Details: [FORMAT.md — Damage recovery](FORMAT.md#damage-recovery) and [recovery discs](FORMAT.md#optional-recovery-discs).

## Build & run

```bash
cd ~/Diskette
./build-app.sh
```

Use `./build-app.sh --no-launch` to build without opening the app.

Requires macOS 13+ and Swift 5.9+ (Xcode toolchain).

## Usage

| Action | How |
|--------|-----|
| New blank disc | **New Disc** (confirms if one is already mounted) |
| Open disc | **Open…**, double-click `.Floppy`, or drop a disc |
| Span large folder | **Span Folder…** or drop a folder with no disc mounted |
| Recovery discs | Span dialog: **None / 1 XOR / 2–8 Reed–Solomon**; **Recover Missing Disc…** after losses |
| Restore span set | **Restore Set…** → all discs or a folder of discs |
| Add files | Drop onto window or **Add…** in the browser |
| Extract | Select items → **Extract…** (keeps folder structure) |
| Repair layout | **Repair Layout…** (opt-in join-bug heuristic; Save to keep) |
| Save | **Save** / **Save As…** (prompted on eject/quit if dirty) |
| Eject | **Eject** |

## CLI

```bash
swift run Diskette --self-test

# Blank disc
.build/release/Diskette --create -o notes.Floppy --media 1.44 --label "Notes"

# Add / list / extract / info
.build/release/Diskette --add notes.Floppy ./MyFolder --path /MyFolder
.build/release/Diskette --list notes.Floppy
.build/release/Diskette --extract notes.Floppy /MyFolder -o ./restored
.build/release/Diskette --info notes.Floppy

# Opt-in fix for join-bug flattened paths (heuristic — review before/after)
.build/release/Diskette --repair-layout notes.Floppy

# Span / unspan
.build/release/Diskette --span ./BigFolder -o ~/Discs --media 1.44 --label "Backup"
.build/release/Diskette --span ./BigFolder -o ~/Discs --media 1.44 --with-recovery
.build/release/Diskette --span ./BigFolder -o ~/Discs --media 1.44 --recovery-discs 3
.build/release/Diskette --unspan-dir ~/Discs -o ~/Restored
.build/release/Diskette --unspan-dir ~/Discs -o ~/Restored --force
.build/release/Diskette --unspan-dir ~/Discs -o ~/Restored --skip-existing

# Rebuild missing data disc(s) from Recovery + survivors (XOR or Reed–Solomon)
.build/release/Diskette --recover-disc ~/Discs -o ~/Discs

# Open GUI with a disc
.build/release/Diskette ~/Discs/Backup-01of03.Floppy
```

## Format

See **[FORMAT.md](FORMAT.md)** for FLOP/1, FLOP/2, and **DISKETTE-SPAN/2**.

## Family

| App | Medium |
|-----|--------|
| PaperTape | Punched paper columns |
| Phonograph | Spiral groove samples |
| Parchment | Sequential leaves |
| **Diskette** | Virtual floppy multi-file containers |

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)**.

## License

Copyright © 2026. All rights reserved.
