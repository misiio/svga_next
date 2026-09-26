# svga_next

A Flutter package for playing SVGA animations. It loads animations from assets, files, URLs, or bytes, and supports playback controls, dynamic content, and optional audio.

SVGA parsing runs in a background isolate. The package decodes images before playback starts and caches loaded animations in memory.

## Requirements

- Flutter 3.19 or later
- Dart 3.3 or later
- A Flutter platform that supports `dart:io`. Web is not supported.

## Install

This package is not published to pub.dev yet. Add it as a path dependency in your app's `pubspec.yaml`, using the path to your local copy:

```yaml
dependencies:
  svga_next:
    path: ../svga_next
```

Then run `flutter pub get`.

## Play an animation

Declare an SVGA file in your app's `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/animation.svga
```

Pass the asset to `SvgaPlayer`:

```dart
import 'package:flutter/material.dart';
import 'package:svga_next/svga_next.dart';

class AnimationView extends StatelessWidget {
  const AnimationView({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 300,
      child: SvgaPlayer(
        source: const SvgaSource.asset('assets/animation.svga'),
        onFinished: () => debugPrint('Animation finished'),
      ),
    );
  }
}
```

`SvgaPlayer` loads and plays the animation when it enters the widget tree. It plays once by default. Set `isLoop: true` to repeat indefinitely, or set `loops` to a specific play count. Use `placeholder` and `errorBuilder` to show a widget while loading or after a load error.

## Load from another source

`SvgaSource` accepts a network URL, local file path, or byte array:

```dart
SvgaSource.network('https://example.com/animation.svga');
SvgaSource.file('/path/to/animation.svga');
SvgaSource.memory(bytes);
```

For network requests, pass `headers` to `SvgaSource.network`. To use your own HTTP client, download the bytes yourself and pass them to `SvgaSource.memory`. `HttpOverrides.global` does not apply to the package's background isolate.

## Control playback

For play, pause, resume, seek, and speed controls, create an `SvgaController` in a `State` class that provides `TickerProvider`:

```dart
class ControlledAnimation extends StatefulWidget {
  const ControlledAnimation({super.key});

  @override
  State<ControlledAnimation> createState() => _ControlledAnimationState();
}

class _ControlledAnimationState extends State<ControlledAnimation>
    with SingleTickerProviderStateMixin {
  late final SvgaController controller = SvgaController(vsync: this);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SvgaPlayer(
      source: const SvgaSource.asset('assets/animation.svga'),
      controller: controller,
      autoPlay: false,
      onLoaded: (_) {
        controller.play(loops: 1);
      },
    );
  }
}
```

Call `controller.pause()`, `resume()`, `stop()`, or `seekTo(frame)` as needed. Set `controller.speed`, `volume`, or `muted` to change playback. `play(from: startFrame, to: endFrame, loops: count)` plays a frame range; `to` is exclusive, and `loops: 0` repeats indefinitely.

## Replace content at runtime

Use `SvgaDynamicEntity` to replace a layer's image or text, draw into a layer, or hide it. Keys are the sprite image keys stored in the SVGA file.

```dart
final dynamicEntity = SvgaDynamicEntity();

dynamicEntity.setText(
  'name',
  text: 'Alex',
  style: const TextStyle(color: Colors.white),
);
dynamicEntity.setImageProvider(
  'avatar',
  provider: const AssetImage('assets/avatar.png'),
  circle: true,
);

SvgaPlayer(
  source: const SvgaSource.asset('assets/animation.svga'),
  dynamicEntity: dynamicEntity,
);
```

Dispose of the entity when its owner is removed. `setImage`, `setTextSpan`, `setDrawer`, and `setHidden` provide other replacement options. `SvgaPlayer` waits up to 1.5 seconds for pending `setImageProvider` calls before autoplay starts. Set `waitForDynamicImages` to change that limit.

## Enable audio

Audio playback requires a backend. Add either [`svga_next_audioplayers`](../svga_next_audioplayers/) or [`svga_next_just_audio`](../svga_next_just_audio/) to your app, then register it before loading animations. For example:

```dart
import 'package:flutter/widgets.dart';
import 'package:svga_next/svga_next.dart';
import 'package:svga_next_audioplayers/svga_next_audioplayers.dart';

void main() {
  SvgaAudio.backend = const SvgaAudioplayersBackend();
  runApp(const MyApp());
}
```

Without a backend, the player ignores audio. To discard audio while decoding, pass `decodeOptions: const SvgaDecodeOptions(enableAudio: false)` to `SvgaPlayer`.

## Cache and decode options

Loaded movies with a source cache key share an in-memory cache. Set `SvgaCache.instance.maxBytes` to change its memory budget. To cache downloaded SVGA files on disk, set `SvgaConfig.diskCacheDirectory` to a writable directory at startup. The disk cache is disabled by default.

Use `SvgaDecodeOptions(maxImageDimension: 1024)` to cap decoded image dimensions, or change `decodeConcurrency` to limit simultaneous image decodes. Pass the options to `SvgaPlayer.decodeOptions` or `SvgaLoader.load(options: ...)`. Call `SvgaLoader.preload(source)` to load a cached animation before showing it.

If you call `SvgaLoader.load` directly, call `release()` on the returned `SvgaMovie` when you no longer need your reference. Assigning it to `SvgaController.movie` gives the controller its own reference. `SvgaPlayer` handles this ownership for its own loads.

## Limitations

- Web is not supported because loading uses `dart:io` and `Isolate.run`.
- Stroke dashing applies to path shapes, but not rectangles or ellipses.

See the [example app](example/) for a complete player with dynamic content and audio.
