# svga_next_just_audio

An optional `just_audio` backend for `svga_next`.

```dart
import 'package:svga_next/svga_next.dart';
import 'package:svga_next_just_audio/svga_next_just_audio.dart';

void main() {
  SvgaAudio.backend = const SvgaJustAudioBackend();
  // Start your Flutter app.
}
```

Register the backend before assigning a movie to a controller. Each SVGA audio
track uses its own player and temporary file. The backend removes the file when
the track is disposed. This backend targets Android, iOS, and macOS. The core
package does not support web.
