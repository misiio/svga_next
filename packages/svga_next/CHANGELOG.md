# Changelog

## Unreleased

- Fix the example dependency conflict by resolving both svga_next and its audio backend from pub.dev.
- Fix bitmap mattes rendering blank when the mask image is stored without the `.matte` suffix. The painter now tries the exact matte key first and then the key without `.matte`.

## 0.1.0

- Initial release of the Flutter SVGA player with SVGA 1.x and 2.x decoding.
- Load animations from assets, files, URLs, or bytes with background parsing and image caching.
- Control playback, loops, frame ranges, speed, and dynamic images, text, and drawing.
- Schedule embedded audio through optional audio backends.
