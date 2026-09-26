# Release the packages

The next release contains `svga_next 0.1.1` and
`svga_next_audioplayers 0.1.1`. `svga_next_just_audio` remains at `0.1.0`.

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

Run `flutter pub publish --dry-run` in the `svga_next` and
`svga_next_audioplayers` directories. Inspect the archive contents. Build
output, local dependency overrides, and generated platform files must not
appear in the archives.

The audioplayers package uses a local dependency override during development.
Its dry run reports this as a hint. Before publishing it, validate against the
published core package as described below.

Commit the release files before publishing to avoid the dirty checkout warning.

## Publish in dependency order

1. Publish `svga_next 0.1.1` first.
2. Wait until `svga_next 0.1.1` is available on pub.dev.
3. Validate and publish `svga_next_audioplayers 0.1.1`.

The core example uses local overrides in this checkout. Its hosted dependencies
can be checked after both packages are published.

To validate the backend releases without local overrides, export the committed
release into a temporary directory. From the repository root, run:

```sh
release_dir=$(mktemp -d)
git archive HEAD packages | tar -x -C "$release_dir"
rm "$release_dir/packages/svga_next_audioplayers/pubspec_overrides.yaml"
rm "$release_dir/packages/svga_next/example/pubspec_overrides.yaml"
```

After the core release is available, run the following in the exported
`svga_next_audioplayers` directory:

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter pub publish --dry-run
```

Resolve validation errors and review any remaining warnings. Run
`flutter pub publish` from the validated package directory when ready to
publish. A dry run does not publish anything.

After both packages are published, run `flutter pub get` and `flutter analyze`
in the exported core example directory to verify that its hosted dependencies
resolve.

## Prepare later versions

Update each changed package's version and changelog. Update the backends'
`svga_next` constraints when they require a newer core release, and keep the
installation snippets and example dependency constraints current.
