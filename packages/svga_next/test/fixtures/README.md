# Test fixtures

`animated.gif` and `animated.webp` are 8x8 images that loop forever through red, green and blue
frames, 100 ms each. Regenerate them with:

```sh
python3 make_animated_gif.py animated.gif
gif2webp -quiet animated.gif -o animated.webp
```
