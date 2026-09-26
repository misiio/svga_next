# Release the packages

The next release contains `svga_next 0.1.2`.
`svga_next_audioplayers` remains at `0.1.1`, and `svga_next_just_audio`
remains at `0.1.0`. Both backend constraints already allow the new core version.

## Validate the checkout

Run these commands from the repository root:

```sh
for package in svga_next svga_next_audioplayers svga_next_just_audio; do
  (
    cd "packages/$package" &&
    flutter pub get &&
    flutter analyze --no-pub &&
    flutter test --no-pub
  ) || exit 1
done
```

Run `flutter pub publish --dry-run` in the `svga_next` directory.
Inspect the archive contents. Build output, local dependency overrides,
and generated platform files must not
appear in the archives.

Commit the release files before publishing to avoid the dirty checkout warning.

## Publish and validate hosted dependencies

1. Run `flutter pub publish` from `packages/svga_next` to publish `svga_next 0.1.2`.
2. Wait until `svga_next 0.1.2` is available on pub.dev.
3. Validate both backends and the example against the hosted release as described below.

Publication requires pub.dev credentials. The backends do not need new releases.

To validate the packages without local overrides, export the committed
release into a temporary directory. From the repository root, run:

```sh
release_dir=$(mktemp -d)
git archive HEAD packages | tar -x -C "$release_dir"
rm "$release_dir/packages/svga_next_audioplayers/pubspec_overrides.yaml"
rm "$release_dir/packages/svga_next_just_audio/pubspec_overrides.yaml"
rm "$release_dir/packages/svga_next/example/pubspec_overrides.yaml"
```

After the core release is available, run the following in each exported
backend directory:

```sh
flutter pub get
flutter pub upgrade svga_next
flutter analyze --no-pub
flutter test --no-pub
```

Run `flutter pub get` and `flutter analyze`
in the exported core example directory to verify that its hosted dependencies
resolve.

## Prepare later versions

Update each changed package's version and changelog. Update the backends'
`svga_next` constraints when they require a newer core release, and keep the
installation snippets and example dependency constraints current.
