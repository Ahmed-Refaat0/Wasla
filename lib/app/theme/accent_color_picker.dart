import 'package:flutter/material.dart';

Future<Color?> showAccentColorPicker(
  BuildContext context, {
  required Color selectedColor,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _AccentColorPickerDialog(
      selectedColor: selectedColor,
    ),
  );
}

class _AccentColorPickerDialog extends StatefulWidget {
  const _AccentColorPickerDialog({required this.selectedColor});

  final Color selectedColor;

  @override
  State<_AccentColorPickerDialog> createState() =>
      _AccentColorPickerDialogState();
}

class _AccentColorPickerDialogState extends State<_AccentColorPickerDialog> {
  static const _presets = [
    Color(0xFF167D76),
    Color(0xFF388E3C),
    Color(0xFF3975D5),
    Color(0xFF8757C6),
    Color(0xFFD65370),
    Color(0xFFE18B2D),
  ];

  late HSVColor _color;

  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(widget.selectedColor);
  }

  Color get _selectedColor => _color.toColor();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('لون التطبيق'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: _selectedColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _selectedColor.withValues(alpha: 0.28),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final preset in _presets)
                  InkWell(
                    onTap: () => setState(
                      () => _color = HSVColor.fromColor(preset),
                    ),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: preset,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _isSelected(preset)
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.transparent,
                          width: 2,
                          strokeAlign: BorderSide.strokeAlignOutside,
                        ),
                      ),
                      child: _isSelected(preset)
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 19,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            _ColorSlider(
              label: 'الدرجة',
              value: _color.hue,
              max: 360,
              activeColor: _selectedColor,
              onChanged: (value) => setState(
                () => _color = _color.withHue(value),
              ),
            ),
            _ColorSlider(
              label: 'التشبع',
              value: _color.saturation,
              max: 1,
              activeColor: _selectedColor,
              onChanged: (value) => setState(
                () => _color = _color.withSaturation(value),
              ),
            ),
            _ColorSlider(
              label: 'السطوع',
              value: _color.value,
              max: 1,
              activeColor: _selectedColor,
              onChanged: (value) => setState(
                () => _color = _color.withValue(value),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedColor),
          child: const Text('تطبيق'),
        ),
      ],
    );
  }

  bool _isSelected(Color color) =>
      color.toARGB32() == _selectedColor.toARGB32();
}

class _ColorSlider extends StatelessWidget {
  const _ColorSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.activeColor,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double max;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 50,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(0, max).toDouble(),
          max: max,
          activeColor: activeColor,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
