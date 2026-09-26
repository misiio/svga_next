# svga_next packages

This repository contains the Flutter SVGA player and optional audio backends.

| Package | Purpose |
| --- | --- |
| [svga_next](packages/svga_next/) | SVGA loading, rendering, and audio scheduling |
| [svga_next_audioplayers](packages/svga_next_audioplayers/) | Audio backend using `audioplayers` |
| [svga_next_just_audio](packages/svga_next_just_audio/) | Audio backend using `just_audio` |

The [example app](packages/svga_next/example/) uses the `audioplayers` backend.
Run `flutter pub get`, `flutter analyze`, and `flutter test` from each package
directory. Run the example from its own directory.

The checked-in `pubspec_overrides.yaml` files select local packages for
development. Package archives exclude these files and use hosted dependencies.

See [RELEASING.md](RELEASING.md) for validation and publication order.
All three packages use the [MIT license](LICENSE).
