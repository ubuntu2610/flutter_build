/// Public entry points for the `flutter_win` package.
///
/// Most consumers only need the CLI (`bin/flutter_win.dart`); this
/// library re-exports the pieces that are useful to embed the cross-build
/// pipeline into a larger Dart tool.
library;

export 'src/build/build_context.dart';
export 'src/build/pipeline.dart';
export 'src/engine_artifacts.dart' show EngineArtifacts, WindowsFlavor;
export 'src/exceptions.dart';
export 'src/flutter_env.dart' show FlutterEnv;
export 'src/project.dart' show FlutterProject, WindowsPluginRef;
export 'src/toolchain.dart' show Toolchain;

/// Package version, kept in sync with `pubspec.yaml`. Bumped manually.
const String packageVersion = '0.1.0-dev';
