# svga_next_audioplayers

An optional `audioplayers` backend for `svga_next`.

## Requirements

Flutter 3.44 and Dart 3.6 or later, matching the requirements of `audioplayers 6.8.1`. Web is not supported.

## Install

```yaml
dependencies:
  svga_next: ^0.1.0
  svga_next_audioplayers: ^0.1.1
```

Run `flutter pub get`.

## Register the backend

```dart
import 'package:svga_next/svga_next.dart';
import 'package:svga_next_audioplayers/svga_next_audioplayers.dart';

void main() {
  SvgaAudio.backend = const SvgaAudioplayersBackend();
  // Start your Flutter app.
}
```

Register the backend before assigning a movie to a controller. Each SVGA audio
track uses its own player and temporary file. The backend removes the file when
the track is disposed.
