import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';

final class MetadataCorrection {
  const MetadataCorrection({
    this.takenAt,
    this.location,
    this.clearLocation = false,
  });

  final DateTime? takenAt;
  final (double, double)? location;
  final bool clearLocation;
}

/// Edits catalogue-only date, time-zone shift and location corrections.
class MetadataEditor extends StatefulWidget {
  const MetadataEditor({required this.item, super.key});

  final MediaItem item;

  @override
  State<MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<MetadataEditor> {
  late DateTime _original;
  late DateTime _date;
  int _shiftHours = 0;
  late final TextEditingController _latitude;
  late final TextEditingController _longitude;
  bool _clearLocation = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final metadata = widget.item.metadata;
    _original = (metadata.takenAt ?? metadata.modifiedAt).toLocal();
    _date = _original;
    _latitude = TextEditingController(text: metadata.latitude?.toString());
    _longitude = TextEditingController(text: metadata.longitude?.toString());
  }

  @override
  void dispose() {
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  DateTime get _result => _date.add(Duration(hours: _shiftHours));

  Future<void> _pickDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (value != null) {
      setState(
        () => _date = DateTime(
          value.year,
          value.month,
          value.day,
          _date.hour,
          _date.minute,
          _date.second,
        ),
      );
    }
  }

  Future<void> _pickTime() async {
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (value != null) {
      setState(
        () => _date = DateTime(
          _date.year,
          _date.month,
          _date.day,
          value.hour,
          value.minute,
        ),
      );
    }
  }

  void _save() {
    (double, double)? location;
    if (!_clearLocation) {
      final latText = _latitude.text.trim(), lonText = _longitude.text.trim();
      final original = widget.item.metadata;
      if (latText.isNotEmpty || lonText.isNotEmpty) {
        final lat = double.tryParse(latText), lon = double.tryParse(lonText);
        if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
          setState(
            () => _error =
                'Enter a latitude (-90 to 90) and longitude (-180 to 180).',
          );
          return;
        }
        if (lat != original.latitude || lon != original.longitude) {
          location = (lat, lon);
        }
      }
    }
    final changedDate = _result != _original;
    Navigator.pop(
      context,
      MetadataCorrection(
        takenAt: changedDate ? _result : null,
        location: location,
        clearLocation: _clearLocation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return AlertDialog(
      title: const AppText('Adjust date and location'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText(
              'Corrections are saved in nexGallery and survive rescans. The original file is not rewritten.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today_rounded),
                  label: Text(localizations.formatMediumDate(_date)),
                ),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(
                    localizations.formatTimeOfDay(
                      TimeOfDay.fromDateTime(_date),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _shiftHours,
              decoration: InputDecoration(
                labelText: context.tr('Time-zone shift'),
                helperText:
                    'Fix photos taken with the camera clock in another zone',
                border: OutlineInputBorder(),
              ),
              items: [
                for (var hours = -12; hours <= 14; hours++)
                  DropdownMenuItem(
                    value: hours,
                    child: Text(
                      hours == 0
                          ? 'No shift'
                          : '${hours > 0 ? '+' : ''}$hours hours',
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _shiftHours = value ?? 0),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _clearLocation,
              title: const AppText('Remove location in nexGallery'),
              onChanged: (value) =>
                  setState(() => _clearLocation = value ?? false),
            ),
            if (!_clearLocation) ...[
              TextField(
                controller: _latitude,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: context.tr('Latitude')),
              ),
              TextField(
                controller: _longitude,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: context.tr('Longitude')),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const AppText('Save')),
      ],
    );
  }
}
