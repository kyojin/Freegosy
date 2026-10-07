# Save interoperability between emulators and RomM clients

Freegosy syncs game saves through RomM, and so do other RomM clients (for
example [Argosy](https://github.com/rommapp/argosy-launcher) on Android). The
same game can be played with different emulators on different machines. This
page records, per platform, how each emulator stores its saves, whether those
files are the same format, and what happens when a save made in one place is
played in another. It's the reference for making saves move between
emulators, one platform at a time.

Each platform section follows the same outline: **formats**, **how each
emulator names its files**, **the interop matrix**, **gaps and
recommendations**. Findings are marked **verified** (checked against real
files or by hand) or **from source** (read in the emulator's code).

Platforms covered so far: [PlayStation (PS1)](#playstation-ps1),
[PlayStation 2 (PS2)](#playstation-2-ps2).

## How Freegosy moves a game save

For reference when reading the matrices:

- **Upload**: the emulator's save strategy (`lib/core/save/strategies/`) lists
  the files for the game (`getSaveFilesWithScreenshots`). One file is uploaded
  under its own name; several go up as one zip. Game saves are tagged on RomM
  with the emulator that made them: the RetroArch core without `_libretro`
  (e.g. `pcsx_rearmed`, as RomM's web player and Argosy name it), otherwise the
  emulator (e.g. `pcsx2`, `duckstation`), in the configured RomM save slot
  (`freegosy` by default).
- **Download**: Freegosy prefers RomM's **newest save in the configured slot**,
  by update time, whoever uploaded it (`RommService.getLatestSave`). If that
  slot has no saves, it falls back to the newest save across all slots. It hands the save to the
  strategy of the emulator on this machine (`restoreSave`), which decides
  where, and under what name, it goes.
- So for a save to cross emulators, the **receiving** strategy must recognise
  the uploaded file (name and format) and write it where its emulator reads it.

To share a save lineage with Argosy, open **Settings → RomM Server → Save
Sync**, set **RomM save slot** to `autosave`, and click **Save slot**. Custom
slot names can contain up to 255 Unicode code points; surrounding whitespace
is removed and a blank value resets to `freegosy`. The setting persists across
restarts and applies to both GUI and headless CLI sync, including queued
offline uploads. Changing it does not move or delete existing saves. Normal
upload retention still applies within
the selected slot. The manual save picker continues to list every slot.

Each sync operation uses the slot selected when it starts, even if the setting
changes during a transfer. Subsequent operations, including a running game's
post-exit upload and queued backups, read the updated setting. Saving the slot
does not reconnect to RomM or trigger queued uploads. Sync operations for the
same game run serially, including across retained service instances; different
games remain independent. Freegosy records which slot was last restored or
pushed for the game's resolved save directory, so returning to a previous slot
restores its save even if that device synced it
earlier. Existing sync history for the default slot is kept.

When a strategy discovers its directory during archive restoration, Freegosy
tracks that lineage for the game and emulator until the directory can be
resolved. A restore invalidates the previous marker before changing files, so
a failed or partial restore cannot leave the previous lineage marked current.

An automatic push into an occupied slot requires the local save to belong to
that lineage. If its pull failed or the local save still belongs to another
slot, the existing conflict dialog lets you keep local progress or restore the
cloud save. Explicit forced pushes keep their existing behavior. Failed or
malformed save-list queries cannot be treated as proof that a slot is empty.

## PlayStation (PS1)

### Format

A PS1 memory card is a **raw 128 KB image** (131,072 bytes): 16 blocks of 8 KB.
Block 0 starts with `MC` and holds a 15-entry directory, one 128-byte entry per
data block: allocation state, size, the next block of the save, the save's
file name and an XOR checksum. The file name starts with a region prefix and
the game's product code, e.g. `BESLES-02605-SETTING` (see
`lib/core/save/ps1_memory_card.dart`).

**DuckStation's `.mcd` and a RetroArch PS1 core's `.srm` are the same format.**
Verified: PCSX-ReARMed's `Crash Bandicoot (Europe).srm` and DuckStation's
`Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)_1.mcd` are both 131,072 bytes
with the same header and directory layout. The only difference is cosmetic:
PCSX-ReARMed fills free blocks with `00`, DuckStation with `FF`. SwanStation
(the libretro port of DuckStation) says so in its own option text: `.srm` and
per-game `.mcd` saves "have internally identical formats and can be converted
between one another via renaming the extension and removing/adding the slot
number (_1)".

### How each emulator names its cards

`<content>` is the file the emulator loaded without its extension: the ROM, or
the `.m3u` of a multi-disc game.

**DuckStation (standalone)**: set by *Memory Card Type* per port
(`[MemoryCards] CardNType` in `settings.ini`, overridable per game in
`gamesettings/<SERIAL>.ini`), in the `memcards` folder. Verified.

| Type (`CardNType`) | File |
|---|---|
| Separate Card Per Game (Serial) (`PerGame`) | `<serial>_N.mcd`, e.g. `SLES-02605_1.mcd` |
| Separate Card Per Game (Title) (`PerGameTitle`, the default for port 1) | `<title>_N.mcd`; the title is `saveName` (else `name`) from DuckStation's own `resources/gamedb.yaml`, or the disc set's from `discsets.yaml` for a multi-disc game when *Use Single Card For Multi-Disc Games* (`UsePlaylistTitle`) is on, unless a card under the disc's own title already exists. Unsafe characters become `_` per platform (Windows: `/ \ < > : " | ? *` and a trailing `.`; Linux: `/ *`; macOS: `/ * :`) |
| Separate Card Per Game (File Title) (`PerGameFileTitle`) | `<content>_N.mcd` |
| Shared Between All Games (`Shared`) | `shared_card_N.mcd` (or `CardNPath`) |
| No Memory Card / Non-Persistent | none |

**RetroArch PS1 cores**: in RetroArch's save folder (per core, e.g.
`saves/PCSX-ReARMed/`, when *Sort Saves into Folders by Core* is on). From
source, plus the verified files above.

| Core | Default (card 1) | Other settings |
|---|---|---|
| PCSX-ReARMed | `<content>.srm` (`pcsx_rearmed_memcard1 = libretro`) | `serial`: `<serial>_1.mcd` (the same name as DuckStation's Serial type); `shared`: `pcsx-card1.mcd`. Card 2 defaults to **shared**, `pcsx-card2.mcd` |
| Beetle / Mednafen PSX (+HW) | `<content>.srm` (*Memory Card 0 Method* = libretro) | Mednafen method: `<content>.0.mcr`; card 2 (when enabled): `<content>.1.mcr`; shared cards: `mednafen_psx_libretro_shared.N.mcr` |
| SwanStation | `<content>.srm` (`Libretro`) | By game code `<code>_N.mcd`; by title `<title>_N.mcd`; shared `duckstation_shared_card_N.mcd` |

With default settings **every RetroArch PS1 core uses `<content>.srm`**.

**Argosy (Android)**: from source (`SavePathResolver.kt`, `SaveDownloader.kt`,
`SavePathRegistry.kt`).

- PS1 runs mostly through RetroArch or Argosy's built-in libretro cores: the
  card is the game's `.srm`, and uploads go to RomM as `<content>.srm`.
- Standalone DuckStation on Android is registered but **disabled** (Android
  DuckStation writes its files unreadable to other apps). When enabled it only
  looks for `<content>_1.mcd` (File Title, port 1).
- On download Argosy writes the bytes to **its own** local path whatever the
  file is called on RomM: a PC-made `.mcd` lands as the game's `.srm`.

### Interop matrix

"verified" means checked by hand with real emulators and RomM: a DuckStation
save played on in RetroArch (PCSX-ReARMed) and back, both through Freegosy.
The other rows follow from the formats and the clients' code.

| Made in → played in | Result | Why |
|---|---|---|
| DuckStation → DuckStation | ✅ | The card is restored under the name this PC's Memory Card Type uses; a shared card gets only this game's saves merged in. |
| DuckStation → RetroArch (Freegosy) | ✅ verified | DuckStation uploads its port-1 card as `<content>.srm` (see below), which is the name the RetroArch core opens. |
| DuckStation → Argosy | ✅ | Argosy writes the bytes to its own `<content>.srm`. ⚠️ Two per-game ports upload a zip; not checked how Argosy handles that. |
| RetroArch (`.srm`) → DuckStation | ✅ verified | A 128 KB `.srm` with the `MC` header is taken as the port-1 card. |
| RetroArch ↔ RetroArch, RetroArch ↔ Argosy | ✅ | The same `<content>.srm` everywhere. |
| Argosy → DuckStation | ✅ | As RetroArch → DuckStation. |
| Older `.mcd` uploads (DuckStation before the `.srm` name, or other clients' `<serial>_1.mcd`) → RetroArch (Freegosy) | ✅ | The RetroArch strategy restores a port-1 PS1 card (`.mcd`, 128 KB, `MC` header) as the game's `<content>.srm`. A card for another port keeps its name, which the core doesn't open by default. An old whole shared card (`shared_card_1.mcd`) lands with every game's saves on it; the game only sees its own. |
| A RetroArch core set to serial / shared / Mednafen cards → anywhere | ⚠️ | The RetroArch strategy only finds `<content>.srm`-style files, so those cards are never uploaded. |

### Gaps and recommendations

1. **Done: DuckStation uploads its port-1 card as `<content>.srm`.** The same
   bytes under the name every RetroArch core, Argosy and RomM's in-browser
   player expect. Other ports keep `<name>_N.mcd` (in a zip with the `.srm`).
   DuckStation's own restore accepts both names.
2. **Done: RetroArch restores a PS1 `.mcd` as `<content>.srm`**, when it is a
   128 KB `MC` card for port 1 (`_1.mcd`, `mcd1` / `card1`, `shared_card_1`,
   or no port in the name), alone or in a zip
   (`RetroArchSaveStrategy.isPs1Port1Card`). This covers `.mcd` saves already
   on RomM and other clients' serial/title cards.
3. **Done (RetroArch, every platform): a stricter save match** (#116). A save
   belongs to the game when it is the ROM name followed by an extension, or
   else has the same title (every word, numbers included; case, punctuation,
   word order and `(…)`/`[…]` tags ignored). Before, one shared word of 3+
   letters was enough, so "Crash Bandicoot 2" could pick up
   `Crash Bandicoot (Europe).srm`.
4. **Later (RetroArch): the cores' own card modes** (serial, shared, `.mcr`).
   Rare, since every core defaults to `.srm`.
5. **Noted: RetroArch's core folder.** The strategy picks the save folder from
   the platform's default core or the per-game core mapping; a game actually
   played with another core keeps its card in that core's folder.
6. **Unverified**: whether RomM's in-browser player (EmulatorJS, RetroArch
   cores) loads a PS1 `.srm` uploaded this way; how Argosy handles a zip of
   two PS1 cards.

### Sources

- DuckStation: this repository's findings in `docs/save-state-sync.md` and the
  DuckStation strategy; files of a real install (`settings.ini`,
  `resources/gamedb.yaml`, `discsets.yaml`, `memcards/`).
- [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed):
  `frontend/libretro.c` (`load_memcards`), `frontend/libretro_core_options.h`.
- [libretro/beetle-psx-libretro](https://github.com/libretro/beetle-psx-libretro):
  `libretro.c` (memcard options, `MDFN_MakeFName` / `MDFNMKF_SAV`).
- [libretro/swanstation](https://github.com/libretro/swanstation):
  `src/libretro/libretro_core_options.h`, `libretro_host_interface.cpp`.
- [rommapp/argosy-launcher](https://github.com/rommapp/argosy-launcher):
  `SavePathResolver.kt`, `SaveDownloader.kt`, `SavePathRegistry.kt`.

## PlayStation 2 (PS2)

### Format

PS2 memory cards come in two shapes that hold the same saves.

**File card**: an **8,650,752-byte image** (16,384 pages of 512 data bytes +
16 ECC bytes), starting with the superblock `Sony PS2 Memory Card Format
1.2.0.0`. Verified: PCSX2's `Mcd001.ps2` and LRPS2's
`system/pcsx2/memcards/Mcd001.ps2` on a real install are both this. Inside is
a FAT-style file system: each save is a top-level **directory** named
`<region prefix><serial><suffix>`, e.g. `BASLUS-20502` or
`BASLUS-21026-PROFILE` (`BA` = US, `BE` = Europe, `BI` = Japan/Asia). One card
holds every game's saves. Unlike a PS1 card there is no simple block list:
moving one game's saves in or out means reading and writing that file system
(clusters, FAT, directory entries, ECC).

**PCSX2 folder card**: a host **directory** with the card's name (e.g.
`memcards/Mcd001.ps2/`), holding an 8 KB `_pcsx2_superblock` and **one folder
per save**, named exactly like the save's directory on a file card. Each
folder holds that save's files plus a `_pcsx2_index` (PCSX2's record of
timestamps, attributes and order). Verified on a real install. With
`McdFolderAutoManage = true` (the default) PCSX2 shows the running game only
its own folders. PCSX2's Memory Cards settings can convert a card between
the two types.

**Play!**: each card is a plain host directory (`vfs/mc0`, `vfs/mc1`) with one
folder per save and no PCSX2 metadata. From source.

So a save folder of a folder card, a save directory of a file card, and a
save folder of a Play! card are the **same files**; only the container
differs.

### How each emulator names its cards

**PCSX2 (standalone)**: in `memcards/` (next to the exe in portable mode),
set by `[MemoryCards] SlotN_Filename` in `inis/PCSX2.ini`, overridable per
game in `gamesettings/`. Verified.

| Slot | Default | Notes |
|---|---|---|
| 1 | `Mcd001.ps2` | File or folder card under the same name; PCSX2 creates a **file** card by default. |
| 2 | `Mcd002.ps2` | An empty filename means no card in slot 2. |
| Multitap | `Mcd-MultitapN-SlotNN.ps2` | Off by default. |

Every game shares the same card unless a per-game setting points it at
another one.

**RetroArch PS2 cores**: from source, plus the verified files above.

| Core | Default | Other setting |
|---|---|---|
| LRPS2 (`pcsx2_libretro`, library name **`LRPS2`**) | *Shared Memory Cards* on: **file** cards `system/pcsx2/memcards/Mcd001.ps2` and `Mcd002.ps2`, shared by every game, **outside the save folder** | Off: `<content>.ps2` in RetroArch's save folder (`saves/LRPS2/` when *Sort Saves into Folders by Core* is on); slot 2 is disabled |
| Play! (`play_libretro`) | Directory cards `vfs/mc0` and `vfs/mc1` under the core's data path | — |

**Argosy (Android)**: from source (`PlatformSaveHandlerRegistry.kt`,
`SavePathRegistry.kt`).

- PS2 only through the Android PCSX2 forks (NetherSX2, AetherSX2, PCSX2),
  in **folder card** mode, in their `files/memcards` folder. File cards are
  not handled.
- **Upload**: a zip of **only this game's save folders**, rooted at the
  folders themselves (e.g. `BASLUS-20502/…`).
- **Download**: accepts that shape and a card-rooted zip, extracting only this
  game's folders into the card. It refuses when several cards hold the game.

### What Freegosy does today

- **PCSX2, folder card**: uploads only this game's save folders (the same
  shape as Argosy). Restore accepts `Mcd00N.ps2/…` bundles, superblock cards
  from other clients and bare save folders, and writes them into the first
  local folder card (or `Mcd001.ps2`). A whole file card from RomM has this
  game's saves taken off it and written in as folders.
- **PCSX2, file card**: uploads only this game's saves, taken off the card
  as save folders (local backups keep the whole card). A pull accepts save
  folders, whole folder cards and whole file cards, and merges only this
  game's saves into the card that holds them, after a `.bak`; the pull
  finishes before PCSX2 starts. Before, the whole 8 MB card went up as this
  game's save, and restoring it on another PC rolled back every other game
  on it.
- **RetroArch, PS2 (LRPS2)**: reads LRPS2's cards (the shared ones in the
  system folder, or the game's own with *Shared Memory Cards* off) and
  uploads only this game's save folders, found by its serial. A pull accepts
  save folders, whole folder cards and whole file cards, and merges only this
  game's saves into the card that holds them, after a `.bak`. Before this, the
  strategy looked in a `PCSX2` save folder that doesn't exist, so nothing was
  uploaded, and restores could land in another core's folder (seen on a real
  install: PS2 cards in `saves/Mupen64Plus-Next/`; fixed in #119).

### Interop matrix

| Made in → played in | Result | Why |
|---|---|---|
| PCSX2 folder card ↔ PCSX2 folder card | ✅ | Only this game's folders move. |
| PCSX2 file card ↔ PCSX2 file card | ✅ | Only this game's save folders move; other games on the card stay. |
| PCSX2 folder card ↔ PCSX2 file card (different PCs) | ✅ | Both upload save folders; a file card takes them onto the card, a folder card as folders (tested file → folder → file). A folder card receiving them gets no `_pcsx2_index`, which PCSX2 accepts (see gap 6). |
| PCSX2 folder card ↔ Argosy | ✅ verified | Both sides upload and restore this game's save folders; checked by hand both ways. |
| PCSX2 file card ↔ Argosy | ✅ | From code: the file card's save folders go into Argosy's folder card, and Argosy's save folders onto the file card. |
| RetroArch (LRPS2) ↔ RetroArch (LRPS2) | ✅ | Only this game's save folders move; checked on a copy of a real card (other games' saves unchanged, mymcplus finds no errors). Not yet verified in the app by hand. |
| PCSX2 folder card → RetroArch (LRPS2) | ✅ | From code: the game's save folders are merged into LRPS2's card; PCSX2's `_pcsx2_index` files are left out. |
| PCSX2 file card → RetroArch (LRPS2) | ✅ | From code: only this game's saves are taken from the whole uploaded card. |
| RetroArch (LRPS2) → PCSX2 folder card | ✅ | From code: the save folders land in the folder card, without a `_pcsx2_index`, which PCSX2 accepts (see gap 6). |
| RetroArch (LRPS2) → PCSX2 file card | ✅ | The save folders are merged into PCSX2's file card. |
| RetroArch (LRPS2) ↔ Argosy | ✅ | From code: both sides move this game's save folders. |
| Anything ↔ Play! | ❌ | Not supported by Freegosy. |

### Gaps and recommendations

1. **Done (RetroArch, every platform): the "newest core folder" fallback**
   (#119). Core folders use each core's `library_name` (`LRPS2` for PS2),
   and a first restore goes to the game's own core folder.
2. **Done (RetroArch, PS2): LRPS2's memory cards.** The strategy reads the
   shared cards in `system/pcsx2/memcards/` (or the game's own
   `<content>.ps2` with *Shared Memory Cards* off) and syncs only this game's
   save folders, merging them back without touching other games' saves.
3. **Done: a PS2 file-card reader/writer** (`Ps2MemoryCard`): reads a file
   card's file system, extracts one game's save directories and writes them
   into another card, keeping everything else byte for byte. Checked against
   mymcplus, an independent implementation.
4. **Done (PCSX2): file cards** sync this game's save folders instead of the
   whole card, and whole-card uploads land in folder cards as folders, which
   closes the folder card ↔ file card gap. With this every PS2 client
   Freegosy knows exchanges saves in one shape: the game's save folders.
5. **Later: Play!**: its directory cards hold the same save folders, so it
   would reuse the same shape.
6. **Verified**: PCSX2 folder card ↔ Argosy, by hand both ways. A save folder
   without its `_pcsx2_index` (file card and LRPS2 uploads have none) is fine
   from source: PCSX2's `MemoryCardFolder.cpp` supports "legacy folder
   memcards without the index file", taking the files' times from the host
   and listing them in directory order.

### Sources

- PCSX2: files of a real install (`inis/PCSX2.ini`, `memcards/Mcd001.ps2/`)
  and the PCSX2 strategy (`lib/core/save/strategies/pcsx2_save_strategy.dart`).
- [PCSX2/pcsx2](https://github.com/PCSX2/pcsx2):
  `pcsx2/SIO/Memcard/MemoryCardFolder.cpp` (folder cards, `_pcsx2_index`).
- [libretro/ps2](https://github.com/libretro/ps2) (LRPS2):
  `libretro/main.cpp` (`retro_load_game`, `library_name`),
  `libretro/libretro_core_options.h` (`pcsx2_shared_memory_cards`),
  `pcsx2/VMManager.cpp` (`LoadSettings`); a real RetroArch install
  (`system/pcsx2/memcards/`).
- [jpd002/Play-](https://github.com/jpd002/Play-): `Source/PS2VM.cpp`
  (`PREF_PS2_MC0_DIRECTORY`).
- [rommapp/argosy-launcher](https://github.com/rommapp/argosy-launcher):
  `PlatformSaveHandlerRegistry.kt` (`Ps2FolderHandler`),
  `SavePathRegistry.kt`.
