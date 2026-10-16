# Changelog

## 0.1.0-dev

- Bundle assembly no longer skips DLLs by basename. The output directory is
  reused across builds, so "if it exists, skip" kept freshly recompiled plugin
  DLLs out of the bundle (new Dart AOT snapshot + stale native DLL mismatch —
  in production this surfaced as `Failed to lookup symbol 'pp_ocr_options_size'
  (error 127)` after the pp_ocr 0.5.x upgrade). All three copy paths
  (plugin DLLs from cmake_build, declared prebuilt DLLs, broad-scan prebuilt
  DLLs) now compare **content**: copy when missing, overwrite when size or
  sha256 differs (same-size binaries are hashed, guarding against recompiled
  DLLs of identical size), skip only when identical. Duplicate basenames from
  multiple sources still resolve to the first hit. mtime is intentionally not
  compared (`File.copy` does not preserve it, so cross-build mtime always
  mismatches and would degrade to a full recopy every build).

- Auto-deploy now deletes the remote app directory before copying. A plain
  scp overlay used to leave stale files behind, which once mixed an old Dart
  kernel snapshot with new native DLLs and caused runtime misbehavior. If the
  remote app is running and locks files, the deploy aborts with a hint.

- Initial scaffold.
- CLI: `doctor`, `precache`, `windows`, `clean`.
- Toolchain: LLVM-MinGW auto-provision, Wine detection.
- Windows engine artifacts fetcher (debug / profile / release).
- CMake orchestrator with cross-compile toolchain file.
- gen_snapshot runner via Wine (release / profile AOT).
- Asset bundler and output packager.
- Parallel three-lane pipeline (native / Dart / assets) with a conservative
  cross-track gate; `--no-parallel` falls back to sequential execution.
- Per-stage timing report, including the wall time saved by parallelism.
- Resource bundling extracted into a standalone `FlutterAssetsStage` so it
  overlaps with the CMake build.
- LLVM-MinGW pinned release upgraded to 20260922.
