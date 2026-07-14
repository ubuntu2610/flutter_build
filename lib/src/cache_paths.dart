// Central resolver for the tool's local caches.
//
// Precedence (highest first):
//   1. Explicit `cacheDirOverride` (from `--cache-dir` global flag).
//   2. Environment variable `FLUTTER_WIN_CACHE`.
//   3. `$XDG_CACHE_HOME/flutter_win` if XDG_CACHE_HOME is set.
//   4. `$HOME/.flutter_win`.
//
// Layout under the root:
//
//   <root>/
//   ├── toolchains/
//   │   └── llvm-mingw-<version>/       # extracted LLVM-MinGW toolchain
//   ├── engine/
//   │   └── <engine-hash>/
//   │       ├── windows-x64/            # embedder + headers + icu
//   │       ├── windows-x64-release/    # gen_snapshot.exe
//   │       └── windows-x64-profile/
//   └── downloads/                      # transient zip/tar files

import 'dart:io';

import 'package:path/path.dart' as p;

class CachePaths {
  CachePaths._(this.root);

  factory CachePaths.resolve({String? cacheDirOverride}) {
    final env = Platform.environment;
    final candidate = cacheDirOverride ??
        env['FLUTTER_WIN_CACHE'] ??
        (env['XDG_CACHE_HOME'] != null
            ? p.join(env['XDG_CACHE_HOME']!, 'flutter_win')
            : p.join(env['HOME'] ?? '/tmp', '.flutter_win'));
    return CachePaths._(Directory(candidate).absolute.path);
  }

  final String root;

  String get toolchainsDir => p.join(root, 'toolchains');
  String get engineDir => p.join(root, 'engine');
  String get downloadsDir => p.join(root, 'downloads');

  String toolchainRoot(String name) => p.join(toolchainsDir, name);
  String engineForHash(String hash) => p.join(engineDir, hash);

  Future<void> ensure() async {
    for (final d in [root, toolchainsDir, engineDir, downloadsDir]) {
      await Directory(d).create(recursive: true);
    }
  }
}
