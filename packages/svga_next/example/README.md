# SVGA player example

This app plays a network animation with dynamic images, text, custom drawing,
and the `svga_next_audioplayers` audio backend. Tap the plus button to update
the combo counter.

Use Flutter 3.27 and Dart 3.6 or later. The example uses `Color.withValues`,
which requires Flutter 3.27. Run these commands from this directory:

```sh
flutter pub get
flutter run
```

The demo downloads SVGA samples and a placeholder image, so it needs internet
access. Run it on Android or iOS. Web is not supported.

In the repository, `pubspec_overrides.yaml` selects the local packages. The
published example resolves the audio backend from pub.dev.
