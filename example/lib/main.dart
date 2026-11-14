// Demo for the calc_bg_color package.
//
//   cd example
//   flutter run -d chrome
//
// Your original single-file version is kept in lib/legacy_main.dart
// (run it with: flutter run -d chrome -t lib/legacy_main.dart).

import 'package:calc_bg_color/calc_bg_color.dart';
import 'package:flutter/material.dart';

void main() => runApp(const DemoApp());

// Logos hosted on Wikimedia, which sends CORS headers (needed on web).
const samples = <(String, String)>[
  (
    'Google',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Google_2015_logo.svg/330px-Google_2015_logo.svg.png',
  ),
  (
    'Flutter',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/1/17/Google-flutter-logo.png/330px-Google-flutter-logo.png',
  ),
  (
    'React',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/a/a7/React-icon.svg/250px-React-icon.svg.png',
  ),
  (
    'Apple (black)',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/f/fa/Apple_logo_black.svg/250px-Apple_logo_black.svg.png',
  ),
  (
    'GitHub (black)',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Octicons-mark-github.svg/250px-Octicons-mark-github.svg.png',
  ),
];

const appBackgrounds = <(String, Color)>[
  ('White', Color(0xFFFFFFFF)),
  ('Brand blue', Color(0xFF1E40AF)),
  ('Dark slate', Color(0xFF0F172A)),
  ('Black', Color(0xFF000000)),
  ('Amber', Color(0xFFF59E0B)),
];

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'calc_bg_color demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _urlController = TextEditingController(text: samples.first.$2);
  String _url = samples.first.$2;
  Color _background = appBackgrounds.first.$2;
  double _width = 180;
  bool _removeBackground = true;
  bool _floodFill = true;
  AdaptiveLogoEffect _effect = AdaptiveLogoEffect.halo;
  LogoEvaluation? _evaluation;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _load(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _url = trimmed;
      _urlController.text = trimmed;
      _evaluation = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = LogoOptions(
      removeBackground: _removeBackground,
      removal: RemovalOptions(floodFill: _floodFill),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('calc_bg_color')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _urlInput(),
              const SizedBox(height: 16),

              // ---- The preview: the logo on your "app background" -------
              Container(
                height: 260,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black12),
                ),
                child: AdaptiveLogo(
                  image: NetworkImage(_url),
                  background: _background,
                  width: _width,
                  effect: _effect,
                  options: options,
                  onEvaluated: (e) => setState(() => _evaluation = e),
                ),
              ),
              const SizedBox(height: 16),
              if (_evaluation != null)
                _EvaluationPanel(
                  evaluation: _evaluation!,
                  onPick: (c) => setState(() => _background = c),
                ),
              const Divider(height: 32),
              _controls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _urlInput() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Logo URL',
                border: OutlineInputBorder(),
              ),
              onSubmitted: _load,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => _load(_urlController.text),
            child: const Text('Load'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, url) in samples)
            ActionChip(label: Text(label), onPressed: () => _load(url)),
        ],
      ),
    ],
  );

  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('App background'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, color) in appBackgrounds)
            ChoiceChip(
              avatar: CircleAvatar(backgroundColor: color),
              label: Text(label),
              selected: _background == color,
              onSelected: (_) => setState(() => _background = color),
            ),
        ],
      ),
      const SizedBox(height: 16),
      const Text('Effect'),
      const SizedBox(height: 8),
      SegmentedButton<AdaptiveLogoEffect>(
        segments: [
          for (final e in AdaptiveLogoEffect.values)
            ButtonSegment(value: e, label: Text(e.name)),
        ],
        selected: {_effect},
        onSelectionChanged: (s) => setState(() => _effect = s.first),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          const SizedBox(width: 90, child: Text('Width')),
          Expanded(
            child: Slider(
              value: _width,
              min: 60,
              max: 320,
              onChanged: (v) => setState(() => _width = v),
            ),
          ),
          Text('${_width.round()} px'),
        ],
      ),
      SwitchListTile(
        title: const Text('Remove solid background box'),
        value: _removeBackground,
        onChanged: (v) => setState(() => _removeBackground = v),
      ),
      SwitchListTile(
        title: const Text('Flood fill from the edges'),
        subtitle: const Text('Off = remove every matching pixel, even inside'),
        value: _floodFill,
        onChanged: _removeBackground
            ? (v) => setState(() => _floodFill = v)
            : null,
      ),
    ],
  );
}

class _EvaluationPanel extends StatelessWidget {
  const _EvaluationPanel({required this.evaluation, required this.onPick});

  final LogoEvaluation evaluation;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    final report = evaluation.contrast;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  report.hasConflict ? Icons.warning_amber : Icons.check_circle,
                  color: report.hasConflict ? Colors.orange : Colors.green,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(report.reason, style: text.bodyMedium)),
              ],
            ),
            const SizedBox(height: 12),
            Text('Logo colors', style: text.titleSmall),
            const SizedBox(height: 4),
            for (final s in report.swatches)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    _Dot(s.swatch.color),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 80,
                      child: Text(ColorMath.toHex(s.swatch.color)),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(
                        '${(s.swatch.share * 100).toStringAsFixed(0)}%',
                      ),
                    ),
                    Text('contrast ${s.contrast.toStringAsFixed(2)}:1'),
                    if (s.blends) ...[
                      const SizedBox(width: 8),
                      const Text(
                        'blends in',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Suggested backgrounds (tap to apply)',
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in evaluation.suggestions)
                  ActionChip(
                    avatar: _Dot(s.color),
                    label: Text(
                      '${ColorMath.toHex(s.color)} · ${s.source.name} · '
                      '${(s.score * 100).toStringAsFixed(0)}',
                    ),
                    onPressed: () => onPick(s.color),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.black26),
    ),
  );
}
