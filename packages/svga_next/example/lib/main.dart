import 'dart:io';

import 'package:flutter/material.dart';
import 'package:svga_next/svga_next.dart';
import 'package:svga_next_audioplayers/svga_next_audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SvgaAudio.backend = const SvgaAudioplayersBackend();
  SvgaConfig.diskCacheDirectory = '${Directory.systemTemp.path}/svga_cache';
  SvgaCache.instance.maxBytes = 96 << 20;
  runApp(const MaterialApp(home: GiftDemo()));
}

class GiftDemo extends StatefulWidget {
  const GiftDemo({super.key});
  @override
  State<GiftDemo> createState() => _GiftDemoState();
}

class _GiftDemoState extends State<GiftDemo> {
  static const _gift = SvgaSource.network(
      'https://cdn.jsdelivr.net/gh/svga/SVGA-Samples@master/kingset.svga');
  final _dynamic = SvgaDynamicEntity();
  int _combo = 1;

  @override
  void initState() {
    super.initState();
    // Starts immediately, in parallel with the SVGA download + parse.
    _dynamic.setImageProvider(
      '99',
      provider: const ResizeImage(
          NetworkImage('https://placehold.jp/150x150.png'),
          width: 160),
      circle: true,
    );
    _dynamic.setText(
      'banner',
      text: 'John',
      style: const TextStyle(
          color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600),
    );
    // Custom drawer: combo counter painted into the "combo" layer.
    _dynamic.setDrawer('banner', drawer: (canvas, bounds, frame, alpha) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'x$_combo',
          style: TextStyle(
              color: Colors.amber.withValues(alpha: alpha),
              fontSize: bounds.height * .8),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, bounds.centerLeft - Offset(0, tp.height / 2));
      tp.dispose();
    });
    // Warm the next gift while this one plays.
    SvgaLoader.preload(const SvgaSource.network(
        'https://cdn.jsdelivr.net/gh/svga/SVGA-Samples@master/posche.svga'));
  }

  @override
  void dispose() {
    _dynamic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 375,
          height: 200,
          child: SvgaPlayer(
            source: _gift,
            dynamicEntity: _dynamic,
            loops: 0,
            fillMode: SvgaFillMode.clear,
            decodeOptions: const SvgaDecodeOptions(maxImageDimension: 1024),
            onLayerTap: (key) => debugPrint('tapped $key'),
            onFinished: () => debugPrint('gift done'),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _combo++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
