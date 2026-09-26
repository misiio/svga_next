# svga_next_audioplayers

An optional `audioplayers` backend for `svga_next`.

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
