# Test fixtures

`animated.gif` and `animated.webp` are 8x8 images that loop forever through red, green and blue
frames, 100 ms each. `animated_400x300.gif` and `animated_400x300.webp` are 400x300 with a red
and a green frame. Regenerate them with:

```sh
python3 make_animated_gif.py animated.gif
gif2webp -quiet animated.gif -o animated.webp
python3 make_animated_gif.py animated_400x300.gif 400 300 2
gif2webp -quiet animated_400x300.gif -o animated_400x300.webp
```
