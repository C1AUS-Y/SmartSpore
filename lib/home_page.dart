import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'classifier.dart';
import 'swin_remote_classifier.dart';

const Map<String, bool> kPoisonousLabels = {
  'Agaricus_campestris': false,
  'Agaricus_xanthodermus': true,
  'Chlorophyllum_molybdites': true,
  'Chlorophyllum_rhacodes': false,
  'Lepiota_cristata': true,
  'Macrolepiota_procera': false,
};

const Map<String, String> kCommonNames = {
  'Agaricus_campestris': 'Field Mushroom',
  'Agaricus_xanthodermus': 'Yellow Stainer',
  'Chlorophyllum_molybdites': 'Green-Spored Parasol',
  'Chlorophyllum_rhacodes': 'Shaggy Parasol',
  'Lepiota_cristata': 'Stinking Dapperling',
  'Macrolepiota_procera': 'Parasol Mushroom',
};

class SpeciesTraits {
  final String cap;
  final String gills;
  final String stalk;

  const SpeciesTraits({
    required this.cap,
    required this.gills,
    required this.stalk,
  });
}

const Map<String, SpeciesTraits> kSpeciesTraits = {
  'Agaricus_campestris': SpeciesTraits(
    cap: 'Smooth, white to cream cap that stays domed with a slightly '
        'inrolled edge.',
    gills: 'Free gills that start pink and darken to chocolate-brown as '
        'spores mature.',
    stalk: 'Short, white stalk with a thin, sometimes faint ring.',
  ),
  'Agaricus_xanthodermus': SpeciesTraits(
    cap: 'Smooth white cap that bruises bright yellow where scratched or '
        'pressed.',
    gills: 'White gills maturing to pink then dark brown, staining yellow '
        'when damaged.',
    stalk: 'Stalk with a bulbous base that yellows strongly when cut.',
  ),
  'Chlorophyllum_molybdites': SpeciesTraits(
    cap: 'Large cap with coarse brown scales over paler flesh.',
    gills: 'Gills that start white but mature to a distinctive '
        'greenish-grey from the spores.',
    stalk: 'Tall, slender stalk with a substantial, movable ring.',
  ),
  'Chlorophyllum_rhacodes': SpeciesTraits(
    cap: 'Cap covered in coarse, upturned brown scales over white flesh, '
        'often bruising reddish where cut.',
    gills: 'Crowded white gills that stay white, never turning green.',
    stalk: 'Smooth stalk with a thick, movable ring and a somewhat '
        'bulbous base.',
  ),
  'Lepiota_cristata': SpeciesTraits(
    cap: 'Small cap with fine reddish-brown scales concentrated toward '
        'the center over pale flesh.',
    gills: 'Free, white to cream gills.',
    stalk: 'Slender, smooth stalk without a persistent ring.',
  ),
  'Macrolepiota_procera': SpeciesTraits(
    cap: 'Large cap opening from an egg shape to broadly umbrella-like, '
        'with coarse brown scales and a raised central boss.',
    gills: 'Free, crowded white gills.',
    stalk: 'Tall, slender, snake-skin patterned stalk with a thick '
        'double ring that can slide up and down.',
  ),
};

const double kMinConfidentThreshold = 0.50;
const double kHighConfidenceThreshold = 0.85;

String advisoryFor(bool? poisonous) {
  if (poisonous == null) {
    return 'Status unknown. Do not eat this mushroom without confirmation from an expert.';
  }

  if (poisonous) {
    return 'Do not consume. If it has already been consumed, contact Poison Control or seek medical help right away.';
  }

  return 'Generally considered edible, but always have a local expert confirm identification before eating any wild mushroom.';
}

String formatSpeciesLabel(String raw) => raw
    .split('_')
    .where((p) => p.isNotEmpty)
    .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
    .join(' ');

String friendlyErrorMessage(Object error) {
  if (error is SocketException ||
      error.toString().contains('Failed host lookup') ||
      error.toString().contains('Connection refused') ||
      error.toString().contains('No internet connection')) {
    return 'No internet connection. Check your Wi-Fi or mobile data and try again.';
  }

  if (error is TimeoutException ||
      error.toString().contains('TimeoutException')) {
    return 'The request took too long. Check your connection and try again.';
  }

  final m = error.toString();

  if (m.contains('warming up') ||
      m.contains('taking longer than usual')) {
    return 'The online model is still starting up. Try again in a moment.';
  }

  return 'Something went wrong. Please try again.';
}

class _Palette {
  static const bg = Color(0xFFF6F4EF);
  static const surface = Color(0xFFFFFFFF);
  static const line = Color(0xFFE6E2D6);
  static const ink = Color(0xFF20241F);
  static const inkFaint = Color(0xFF767A6E);
  static const moss = Color(0xFF44603F);
  static const mossSoft = Color(0xFFE4EAE0);
  static const rust = Color(0xFFA24A32);
  static const rustSoft = Color(0xFFF3E4DD);
  static const amber = Color(0xFF9A6B14);
  static const amberSoft = Color(0xFFFBF0D9);
}

enum MushroomAngle { top, bottom, side }

extension MushroomAngleLabel on MushroomAngle {
  String get label {
    switch (this) {
      case MushroomAngle.top:
        return 'Top';
      case MushroomAngle.bottom:
        return 'Bottom';
      case MushroomAngle.side:
        return 'Side';
    }
  }

  String get instruction {
    switch (this) {
      case MushroomAngle.top:
        return 'Photo of the cap from above';
      case MushroomAngle.bottom:
        return 'Photo of the gills underneath';
      case MushroomAngle.side:
        return 'Photo of the stalk from the side';
    }
  }
}

enum ModelMode { offline, online }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _offlineClassifier = Classifier();
  final _onlineClassifier = SwinRemoteClassifier();
  final _picker = ImagePicker();
  final _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  ModelMode? _mode;

  bool _hasInternet = false;

  bool _offlineLoaded = false;
  bool _onlineLoaded = false;
  bool _switching = false;
  bool _busy = false;

  final Map<MushroomAngle, File> _images = {};

  List<ClassificationResult> _results = [];

  String _status = 'Choose a model below to get started.';

  MushroomClassifier? get _classifier {
    if (_mode == null) return null;

    return _mode == ModelMode.offline
        ? _offlineClassifier
        : _onlineClassifier;
  }

  bool get _allImagesReady =>
      _images.length == MushroomAngle.values.length;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _offlineClassifier.dispose();
    _onlineClassifier.dispose();
    super.dispose();
  }

  Future<void> _initConnectivity() async {
    final result = await _connectivity.checkConnectivity();

    if (!mounted) return;

    _updateInternet(result);

    _connectivitySub =
        _connectivity.onConnectivityChanged.listen(_updateInternet);
  }

  void _updateInternet(List<ConnectivityResult> result) {
    final connected = result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.mobile);

    if (!mounted) return;

    setState(() => _hasInternet = connected);

    if (!connected && _mode == ModelMode.online) {
      _selectMode(ModelMode.offline);
    }
  }

  bool _loaded(ModelMode mode) =>
      mode == ModelMode.offline
          ? _offlineLoaded
          : _onlineLoaded;

  Future<void> _selectMode(ModelMode mode) async {
    if ((_mode == mode && _loaded(mode)) || _switching) {
      return;
    }

    if (mode == ModelMode.online && !_hasInternet) {
      setState(() {
        _status =
            'Connect to the internet to use the online model.';
      });
      return;
    }

    setState(() {
      _switching = true;
      _results = [];
    });

    try {
      if (mode == ModelMode.offline && !_offlineLoaded) {
        setState(() => _status = 'Loading offline model…');

        await _offlineClassifier.load();

        _offlineLoaded = true;
      }

      if (mode == ModelMode.online && !_onlineLoaded) {
        setState(() => _status = 'Connecting to online model…');

        await _onlineClassifier.load();

        _onlineLoaded = true;
      }

      if (!mounted) return;

      setState(() {
        _mode = mode;

        _status = mode == ModelMode.offline
            ? 'Offline model ready. Take all three photos to identify.'
            : 'Online model ready. Take all three photos to identify.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = friendlyErrorMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  Future<void> _pickImage(
    MushroomAngle angle,
    ImageSource source,
  ) async {
    final picked = await _picker.pickImage(
      source: source,
      maxWidth: 1024,
    );

    if (picked == null) return;

    setState(() {
      _images[angle] = File(picked.path);
      _results = [];
    });
  }

  Future<void> _showSourcePicker(MushroomAngle angle) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(
                Icons.camera_alt,
                size: 26,
              ),
              title: const Text(
                'Camera',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () =>
                  Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                size: 26,
              ),
              title: const Text(
                'Gallery',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () =>
                  Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source != null) {
      await _pickImage(angle, source);
    }
  }

  Future<void> _classifyAll() async {
    final classifier = _classifier;

    if (!_allImagesReady ||
        classifier == null ||
        !classifier.isReady ||
        _busy) {
      return;
    }

    setState(() => _busy = true);

    try {
      final files = [
        _images[MushroomAngle.top]!,
        _images[MushroomAngle.bottom]!,
        _images[MushroomAngle.side]!,
      ];

      final results = await classifier.classifyMultiple(files, topK: 6);

      if (mounted) {
        setState(() => _results = results);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = friendlyErrorMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _resetPhotos() {
    setState(() {
      _images.clear();
      _results = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final classifier = _classifier;

    final canIdentify = !_busy &&
        !_switching &&
        _allImagesReady &&
        classifier != null &&
        classifier.isReady;

    final statusHighlighted =
        _mode == null || !_switching;

    return Scaffold(
      backgroundColor: _Palette.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),

              const Text(
                'Mushroom Classifier',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: _Palette.ink,
                  height: 1.15,
                ),
              ),

              const SizedBox(height: 16),

              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    margin:
                        const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: statusHighlighted
                          ? _Palette.moss
                          : _Palette.inkFaint,
                      shape: BoxShape.circle,
                    ),
                  ),

                  const SizedBox(width: 10),

                  Expanded(
                    child: Text(
                      _status,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: statusHighlighted
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: statusHighlighted
                            ? _Palette.moss
                            : _Palette.inkFaint,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 34),

              const _SectionLabel(text: 'MODEL'),

              const SizedBox(height: 6),

              const Text(
                'Tap a model to select it:',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: _Palette.inkFaint,
                ),
              ),

              const SizedBox(height: 12),

              _ModelSwitcher(
                mode: _mode,
                hasInternet: _hasInternet,
                switching: _switching,
                onSelect: _selectMode,
              ),

              const SizedBox(height: 34),

              const _SectionLabel(text: 'CAPTURE'),

              const SizedBox(height: 10),

              const Text(
                'Provide top, bottom, and side photos of the mushroom '
                'for the model to generate accurate identifications.',
                style: TextStyle(
                  fontSize: 16,
                  color: _Palette.inkFaint,
                  height: 1.45,
                ),
              ),

              const SizedBox(height: 16),

              ...List.generate(
                MushroomAngle.values.length,
                (i) {
                  final angle =
                      MushroomAngle.values[i];

                  return Padding(
                    padding: EdgeInsets.only(
                      bottom:
                          i ==
                                  MushroomAngle
                                      .values
                                      .length -
                              1
                          ? 0
                          : 10,
                    ),
                    child: _ImageSlot(
                      index: i + 1,
                      angle: angle,
                      imageFile: _images[angle],
                      onTap: _busy
                          ? null
                          : () =>
                              _showSourcePicker(angle),
                    ),
                  );
                },
              ),

              if (_allImagesReady && _mode != null && _results.isEmpty) ...[
                const SizedBox(height: 14),
                const _ClassificationBreakdown(),
              ],

              const SizedBox(height: 24),

              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: FilledButton(
                        onPressed:
                            canIdentify
                                ? _classifyAll
                                : null,
                        style:
                            FilledButton.styleFrom(
                          backgroundColor:
                              canIdentify
                                  ? _Palette.moss
                                  : _Palette.ink,
                          disabledBackgroundColor:
                              _Palette.ink.withValues(
                            alpha: 0.25,
                          ),
                          shape:
                              RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                              12,
                            ),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'IDENTIFY',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight:
                                FontWeight.w600,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 10),

                  _DeleteButton(
                    onPressed:
                        _busy ? null : _resetPhotos,
                  ),
                ],
              ),

              if (_busy) ...[
                const SizedBox(height: 32),
                const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child:
                        CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: _Palette.moss,
                    ),
                  ),
                ),
              ],

              if (!_busy && _results.isNotEmpty) ...[
                const SizedBox(height: 36),
                const _SectionLabel(text: 'RESULT'),
                const SizedBox(height: 14),
                _ResultsSection(
                  results: _results,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ClassificationBreakdown extends StatelessWidget {
  final String? speciesLabel;

  const _ClassificationBreakdown({this.speciesLabel});

  @override
  Widget build(BuildContext context) {
    final traits =
        speciesLabel == null ? null : kSpeciesTraits[speciesLabel];

    final commonName =
        speciesLabel == null ? null : kCommonNames[speciesLabel];

    final title = traits == null
        ? 'How this was classified'
        : 'Why this was identified as ${formatSpeciesLabel(speciesLabel!)}';

    final topText = traits?.cap ??
        'Cap shape, color and surface';
    final bottomText = traits?.gills ??
        'Gills and underside features';
    final sideText = traits?.stalk ??
        'Stalk shape and overall structure';

    final footer = traits == null
        ? 'These photos are combined to estimate the most likely species.'
        : 'These traits, seen across your top, bottom, and side photos, '
            'are what the photos were matched against'
            '${commonName != null ? ' for the $commonName' : ''}.';

    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: _Palette.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _Palette.line,
          ),
        ),
        child: ExpansionTile(
          initiallyExpanded: traits != null,
          tilePadding:
              const EdgeInsets.symmetric(
            horizontal: 14,
          ),
          childrenPadding:
              const EdgeInsets.fromLTRB(
            14,
            0,
            14,
            14,
          ),
          iconColor: _Palette.inkFaint,
          collapsedIconColor:
              _Palette.inkFaint,
          title: Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: _Palette.ink,
            ),
          ),
          children: [
            _BreakdownLine(
              icon: Icons.camera_alt_outlined,
              title: 'Top',
              text: topText,
            ),
            _BreakdownLine(
              icon: Icons.flip_camera_android_outlined,
              title: 'Bottom',
              text: bottomText,
            ),
            _BreakdownLine(
              icon: Icons.straighten_outlined,
              title: 'Side',
              text: sideText,
            ),
            const SizedBox(height: 4),
            Text(
              footer,
              style: const TextStyle(
                fontSize: 13,
                color: _Palette.inkFaint,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _BreakdownLine({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 17,
            color: _Palette.moss,
          ),
          const SizedBox(width: 9),
          Text(
            '$title — ',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: _Palette.ink,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13.5,
                color: _Palette.inkFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelSwitcher extends StatelessWidget {
  final ModelMode? mode;
  final bool hasInternet;
  final bool switching;
  final ValueChanged<ModelMode> onSelect;

  const _ModelSwitcher({
    required this.mode,
    required this.hasInternet,
    required this.switching,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ModelOption(
                label: 'Offline',
                subtitle: 'On-device',
                selected:
                    mode == ModelMode.offline,
                enabled: !switching,
                onTap: () =>
                    onSelect(ModelMode.offline),
              ),
            ),

            const SizedBox(width: 10),

            Expanded(
              child: _ModelOption(
                label: 'Online',
                subtitle: hasInternet
                    ? 'Swin, Internet'
                    : 'Needs Internet',
                selected:
                    mode == ModelMode.online,
                enabled:
                    hasInternet && !switching,
                onTap: () =>
                    onSelect(ModelMode.online),
              ),
            ),
          ],
        ),

        if (switching) ...[
          const SizedBox(height: 10),
          const Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child:
                    CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _Palette.moss,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Switching model…',
                style: TextStyle(
                  fontSize: 15,
                  color: _Palette.inkFaint,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ModelOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ModelOption({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? _Palette.mossSoft
        : _Palette.surface;

    final border = selected
        ? _Palette.moss
        : _Palette.line;

    final icon = selected
        ? _Palette.moss
        : _Palette.inkFaint;

    final text = selected
        ? _Palette.moss
        : _Palette.ink;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: bg,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration:
                const Duration(milliseconds: 180),
            padding:
                const EdgeInsets.symmetric(
              vertical: 16,
              horizontal: 14,
            ),
            decoration: BoxDecoration(
              borderRadius:
                  BorderRadius.circular(14),
              border: Border.all(
                color: border,
                width: selected ? 2.2 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: _Palette.moss
                            .withValues(
                          alpha: 0.18,
                        ),
                        blurRadius: 10,
                        offset:
                            const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 22,
                    color: icon,
                  ),

                  const SizedBox(width: 10),

                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight:
                                FontWeight.w700,
                            color: text,
                          ),
                        ),

                        const SizedBox(height: 2),

                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: selected
                                ? _Palette.moss
                                    .withValues(
                                  alpha: 0.75,
                                )
                                : _Palette.inkFaint,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (!selected)
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: enabled
                          ? _Palette.inkFaint
                          : _Palette.line,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel({
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
        color: _Palette.ink,
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const _DeleteButton({
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    return Tooltip(
      message: 'Clear photos and start over',
      child: SizedBox(
        height: 56,
        width: 56,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            color: enabled
                ? _Palette.rustSoft
                : _Palette.rustSoft.withValues(
                    alpha: 0.4,
                  ),
            child: InkWell(
              onTap: onPressed,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(14),
                  border: Border.all(
                    color: enabled
                        ? _Palette.rust.withValues(
                            alpha: 0.35,
                          )
                        : _Palette.line,
                    width: 1.4,
                  ),
                  boxShadow: enabled
                      ? [
                          BoxShadow(
                            color: _Palette.rust
                                .withValues(
                              alpha: 0.12,
                            ),
                            blurRadius: 8,
                            offset:
                                const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 24,
                  color: enabled
                      ? _Palette.rust
                      : _Palette.inkFaint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageSlot extends StatelessWidget {
  final int index;
  final MushroomAngle angle;
  final File? imageFile;
  final VoidCallback? onTap;

  const _ImageSlot({
    required this.index,
    required this.angle,
    required this.imageFile,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final filled = imageFile != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: _Palette.surface,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius:
                  BorderRadius.circular(14),
              border: Border.all(
                color: _Palette.line,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: Text(
                    '0$index',
                    style: TextStyle(
                      fontSize: 15,
                      fontFeatures: const [
                        FontFeature.tabularFigures(),
                      ],
                      color: filled
                          ? _Palette.moss
                          : _Palette.inkFaint,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(10),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: filled
                        ? Image.file(
                            imageFile!,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: _Palette.bg,
                            child:
                                const Icon(
                              Icons.add,
                              color:
                                  _Palette.inkFaint,
                              size: 20,
                            ),
                          ),
                  ),
                ),

                const SizedBox(width: 14),

                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        angle.label,
                        style: const TextStyle(
                          fontWeight:
                              FontWeight.w700,
                          fontSize: 17,
                          color: _Palette.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        angle.instruction,
                        style: const TextStyle(
                          fontSize: 14.5,
                          color:
                              _Palette.inkFaint,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                Icon(
                  filled
                      ? Icons.check_circle
                      : Icons.chevron_right,
                  color: filled
                      ? _Palette.moss
                      : _Palette.line,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultsSection extends StatelessWidget {
  final List<ClassificationResult> results;

  const _ResultsSection({
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    final top = results.first;
    final rest = results.skip(1).toList();

    if (top.confidence < kMinConfidentThreshold) {
      return const _UnclearImageCard();
    }

    if (top.confidence < kHighConfidenceThreshold) {
      return Column(
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          _TopResultCard(result: top),

          const SizedBox(height: 10),

          const _InconclusiveCard(),

          const SizedBox(height: 14),
          _ClassificationBreakdown(speciesLabel: top.label),

          if (rest.isNotEmpty) ...[
            const SizedBox(height: 14),
            _OtherPossibilities(
              results: rest,
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        _TopResultCard(result: top),

        const SizedBox(height: 10),

        const Text(
          'Reference only. Please confirm with an expert before consuming any wild mushrooms.',
          style: TextStyle(
            fontSize: 14,
            color: _Palette.inkFaint,
            height: 1.45,
          ),
        ),

        const SizedBox(height: 14),
        _ClassificationBreakdown(speciesLabel: top.label),

        if (rest.isNotEmpty) ...[
          const SizedBox(height: 14),
          _OtherPossibilities(
            results: rest,
          ),
        ],
      ],
    );
  }
}

class _OtherPossibilities extends StatelessWidget {
  final List<ClassificationResult> results;

  const _OtherPossibilities({
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        iconColor: _Palette.inkFaint,
        collapsedIconColor:
            _Palette.inkFaint,
        title: const Text(
          'Other possibilities',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: _Palette.inkFaint,
          ),
        ),
        children: results
            .map(
              (r) => _ResultRow(result: r),
            )
            .toList(),
      ),
    );
  }
}

class _UnclearImageCard extends StatelessWidget {
  const _UnclearImageCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _Palette.rustSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _Palette.line,
        ),
      ),
      child: const Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                size: 22,
                color: _Palette.rust,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Image Invalid',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight:
                        FontWeight.w700,
                    color: _Palette.rust,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 10),

          Text(
            'Please scan closer or ensure better lighting. Retake clear photos of the cap, gills, and stalk.',
            style: TextStyle(
              fontSize: 16,
              color: _Palette.rust,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InconclusiveCard extends StatelessWidget {
  const _InconclusiveCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _Palette.amberSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _Palette.line,
        ),
      ),
      child: const Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 22,
                color: _Palette.amber,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Low Confidence Match',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight:
                        FontWeight.w700,
                    color: _Palette.amber,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 10),

          Text(
            'Do not consume. This identification is below the app\'s high-confidence threshold, so it should not be trusted for safety. Have this mushroom checked by a local expert before considering consumption.',
            style: TextStyle(
              fontSize: 16,
              color: _Palette.amber,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TopResultCard extends StatelessWidget {
  final ClassificationResult result;

  const _TopResultCard({
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final poisonous =
        kPoisonousLabels[result.label];

    final commonName =
        kCommonNames[result.label];

    final pct = result.confidence * 100;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _Palette.line,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          _PoisonousBadge(
            isPoisonous: poisonous,
          ),

          const SizedBox(height: 14),

          Text(
            formatSpeciesLabel(result.label),
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: _Palette.ink,
              height: 1.15,
            ),
          ),

          if (commonName != null) ...[
            const SizedBox(height: 4),
            Text(
              commonName,
              style: const TextStyle(
                fontSize: 17,
                color: _Palette.inkFaint,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],

          const SizedBox(height: 16),

          Row(
            crossAxisAlignment:
                CrossAxisAlignment.baseline,
            textBaseline:
                TextBaseline.alphabetic,
            children: [
              Text(
                pct.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _Palette.ink,
                  fontFeatures: [
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),

              const Text(
                '%',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _Palette.inkFaint,
                ),
              ),

              const SizedBox(width: 8),

              const Text(
                'CONFIDENCE',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: _Palette.inkFaint,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          ClipRRect(
            borderRadius:
                BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value:
                  result.confidence.clamp(0, 1),
              minHeight: 5,
              backgroundColor:
                  _Palette.line,
              valueColor:
                  AlwaysStoppedAnimation(
                poisonous == true
                    ? _Palette.rust
                    : _Palette.moss,
              ),
            ),
          ),

          const SizedBox(height: 14),

          Container(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: poisonous == true
                  ? _Palette.rustSoft
                  : _Palette.mossSoft,
              borderRadius:
                  BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Icon(
                  poisonous == true
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline,
                  size: 18,
                  color: poisonous == true
                      ? _Palette.rust
                      : _Palette.moss,
                ),

                const SizedBox(width: 8),

                Expanded(
                  child: Text(
                    advisoryFor(poisonous),
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      color: poisonous == true
                          ? _Palette.rust
                          : _Palette.moss,
                      fontWeight:
                          FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final ClassificationResult result;

  const _ResultRow({
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final commonName =
        kCommonNames[result.label];

    return Container(
      padding:
          const EdgeInsets.symmetric(
        vertical: 10,
      ),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: _Palette.line,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  formatSpeciesLabel(
                    result.label,
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _Palette.inkFaint,
                  ),
                ),

                if (commonName != null)
                  Text(
                    commonName,
                    style: const TextStyle(
                      fontSize: 13,
                      color:
                          _Palette.inkFaint,
                      fontStyle:
                          FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),

          Text(
            '${(result.confidence * 100).toStringAsFixed(1)}%',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _Palette.inkFaint,
              fontFeatures: [
                FontFeature.tabularFigures(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PoisonousBadge extends StatelessWidget {
  final bool? isPoisonous;

  const _PoisonousBadge({
    required this.isPoisonous,
  });

  @override
  Widget build(BuildContext context) {
    late Color color;
    late Color bg;
    late String label;

    if (isPoisonous == null) {
      color = _Palette.inkFaint;
      bg = _Palette.bg;
      label = 'UNKNOWN';
    } else if (isPoisonous!) {
      color = _Palette.rust;
      bg = _Palette.rustSoft;
      label = 'POISONOUS';
    } else {
      color = _Palette.moss;
      bg = _Palette.mossSoft;
      label = 'EDIBLE';
    }

    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 15,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius:
            BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(
            alpha: 0.18,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}