import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../apps/data/installed_apps_service.dart';
import '../../apps/domain/installed_app.dart';
import '../../transfer/domain/transfer_file_source.dart';

enum _FileCategory {
  apps('تطبيقات', Icons.android_rounded, FileType.custom, ['apk']),
  videos('فيديوهات', Icons.movie_rounded, FileType.video, null),
  audio('صوتيات', Icons.music_note_rounded, FileType.audio, null),
  photos('صور', Icons.photo_rounded, FileType.image, null),
  documents('ملفات', Icons.folder_rounded, FileType.custom, [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'rtf',
    'csv',
    'zip',
    '7z',
    'rar',
    'json',
    'xml',
    'md',
  ]);

  const _FileCategory(this.label, this.icon, this.type, this.extensions);

  final String label;
  final IconData icon;
  final FileType type;
  final List<String>? extensions;
}

class FileSelectionScreen extends StatefulWidget {
  const FileSelectionScreen({super.key});

  @override
  State<FileSelectionScreen> createState() => _FileSelectionScreenState();
}

class _FileSelectionScreenState extends State<FileSelectionScreen> {
  final InstalledAppsService _installedAppsService = InstalledAppsService();
  final Map<String, _SelectedFile> _files = {};
  final Set<String> _selectedPaths = {};
  final Map<String, InstalledApp> _installedApps = {};
  final Set<String> _selectedApps = {};
  _FileCategory _category = _FileCategory.photos;
  bool _isPicking = false;
  bool _isLoadingApps = false;
  bool _appsLoaded = false;
  String? _errorMessage;
  String? _appsErrorMessage;

  List<_SelectedFile> get _categoryFiles =>
      _files.values.where((file) => file.category == _category).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  List<_SelectedFile> get _selectedFiles => _files.entries
      .where((entry) => _selectedPaths.contains(entry.key))
      .map((entry) => entry.value)
      .toList();
  List<InstalledApp> get _selectedInstalledApps => _installedApps.values
      .where((app) => _selectedApps.contains(app.packageName))
      .toList();
  int get _selectedSize =>
      _selectedFiles.fold<int>(0, (sum, file) => sum + file.size) +
      _selectedInstalledApps.fold<int>(
        0,
        (sum, app) => sum + app.apkSizes.fold<int>(0, (a, b) => a + b),
      );

  Future<void> _browseCategory() async {
    if (_category == _FileCategory.apps && Platform.isAndroid) {
      await _loadInstalledApps();
      return;
    }
    if (_isPicking) return;
    setState(() {
      _isPicking = true;
      _errorMessage = null;
    });

    try {
      final pickedFiles = await FilePicker.pickFiles(
        dialogTitle: 'اختر ${_category.label}',
        type: _category.type,
        allowedExtensions: _category.extensions,
      );
      if (!mounted || pickedFiles.isEmpty) return;

      final added = <String, _SelectedFile>{};
      for (final pickedFile in pickedFiles) {
        final path = pickedFile.path;
        if (path == null || path.isEmpty) {
          throw FileSystemException(
            'تعذّر الوصول إلى الملف المحدد.',
            pickedFile.name,
          );
        }
        final file = File(path);
        if (!await file.exists()) {
          throw FileSystemException('الملف لم يعد متاحًا.', path);
        }
        final size = await file.length();
        final entry = _SelectedFile(
          path: path,
          name: pickedFile.name,
          size: size,
          category: _category,
        );
        added[_fileKey(entry)] = entry;
      }

      if (!mounted) return;
      setState(() {
        for (final entry in added.entries) {
          _files.putIfAbsent(entry.key, () => entry.value);
          _selectedPaths.add(entry.key);
        }
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _errorMessage = 'تعذّر فتح منتقي الملفات: ${error.message}',
        );
      }
    } on FileSystemException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _loadInstalledApps() async {
    if (_isLoadingApps) return;
    setState(() {
      _isLoadingApps = true;
      _appsErrorMessage = null;
    });
    try {
      final apps = await _installedAppsService.listUserApps();
      if (!mounted) return;
      setState(() {
        _installedApps
          ..clear()
          ..addEntries(apps.map((app) => MapEntry(app.packageName, app)));
        _selectedApps.removeWhere(
          (packageName) => !_installedApps.containsKey(packageName),
        );
        _appsLoaded = true;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _appsErrorMessage =
              'تعذّر قراءة التطبيقات المثبتة: ${error.message ?? error.code}',
        );
      }
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _appsErrorMessage = error.message);
    } on FileSystemException catch (error) {
      if (mounted) setState(() => _appsErrorMessage = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _appsErrorMessage = error.message);
    } finally {
      if (mounted) setState(() => _isLoadingApps = false);
    }
  }

  void _toggleApp(InstalledApp app, bool selected) {
    setState(() {
      if (selected) {
        _selectedApps.add(app.packageName);
      } else {
        _selectedApps.remove(app.packageName);
      }
    });
  }

  Future<void> _submitSelection() async {
    try {
      final sources = <TransferFileSource>[
        for (final file in _selectedFiles)
          TransferFileSource(
            name: file.name,
            size: file.size,
            openRead: File(file.path).openRead,
          ),
        ...await _installedAppsService.createTransferSources(
          _selectedInstalledApps,
        ),
      ];
      if (mounted) Navigator.pop(context, sources);
    } on FileSystemException catch (error) {
      if (mounted) setState(() => _appsErrorMessage = error.message);
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _appsErrorMessage = error.message);
    }
  }

  void _toggleFile(_SelectedFile file, bool selected) {
    final key = _fileKey(file);
    setState(() {
      if (selected) {
        _selectedPaths.add(key);
      } else {
        _selectedPaths.remove(key);
      }
    });
  }

  String _fileKey(_SelectedFile file) => '${file.path}\u0000${file.size}';

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var size = bytes / 1024;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final files = _categoryFiles;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('اختيار الملفات'),
          centerTitle: false,
          actions: [
            if (_files.isNotEmpty || _selectedApps.isNotEmpty)
              TextButton(
                onPressed: () => setState(() {
                  _files.clear();
                  _selectedPaths.clear();
                  _selectedApps.clear();
                }),
                child: const Text('مسح الكل'),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 92,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: _FileCategory.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 9),
                  itemBuilder: (context, index) {
                    final category = _FileCategory.values[index];
                    final count =
                        _selectedFiles
                            .where((file) => file.category == category)
                            .length +
                        (category == _FileCategory.apps && Platform.isAndroid
                            ? _selectedApps.length
                            : 0);
                    final selected = category == _category;
                    return _CategoryChip(
                      category: category,
                      count: count,
                      selected: selected,
                      onTap: () {
                        setState(() => _category = category);
                        if (category == _FileCategory.apps &&
                            Platform.isAndroid &&
                            !_appsLoaded) {
                          _loadInstalledApps();
                        }
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _category == _FileCategory.apps
                                ? Platform.isAndroid
                                      ? 'التطبيقات المثبتة'
                                      : 'ملفات تثبيت APK'
                                : _category.label,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _category == _FileCategory.apps
                                ? Platform.isAndroid
                                      ? 'اختر تطبيقًا أو أكثر لإرسال ملفات APK'
                                      : 'اختر ملفات APK من جهازك'
                                : 'حدد ملفات متعددة من جهازك',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_isPicking || _isLoadingApps)
                          ? null
                          : _browseCategory,
                      icon: (_isPicking || _isLoadingApps)
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded, size: 18),
                      label: Text(
                        _isLoadingApps
                            ? 'جارٍ التحميل'
                            : _category == _FileCategory.apps &&
                                  Platform.isAndroid
                            ? 'تحديث التطبيقات'
                            : _isPicking
                            ? 'جارٍ الفتح'
                            : 'استعراض',
                      ),
                    ),
                  ],
                ),
              ),
              if (_category == _FileCategory.apps &&
                  Platform.isAndroid &&
                  _appsErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _PickerMessage(
                    message: _appsErrorMessage!,
                    isError: true,
                  ),
                ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _PickerMessage(message: _errorMessage!, isError: true),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _category == _FileCategory.apps && Platform.isAndroid
                      ? KeyedSubtree(
                          key: ValueKey(_category),
                          child: _buildInstalledApps(),
                        )
                      : files.isEmpty
                      ? _EmptyCategory(
                          key: ValueKey(_category),
                          category: _category,
                          onBrowse: _browseCategory,
                          isPicking: _isPicking,
                        )
                      : ListView.separated(
                          key: ValueKey(_category),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                          itemCount: files.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final file = files[index];
                            return _FileTile(
                              file: file,
                              selected: _selectedPaths.contains(_fileKey(file)),
                              sizeLabel: _formatSize(file.size),
                              onChanged: (selected) =>
                                  _toggleFile(file, selected),
                            );
                          },
                        ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.line)),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'تم تحديد ${_selectedFiles.length} ملف و'
                          '${_selectedApps.length} تطبيق · '
                          '${_formatSize(_selectedSize)}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed:
                            _selectedPaths.isEmpty && _selectedApps.isEmpty
                            ? null
                            : _submitSelection,
                        icon: const Icon(Icons.send_rounded, size: 18),
                        label: const Text('إرسال'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstalledApps() {
    if (_isLoadingApps) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_appsLoaded && _appsErrorMessage == null) {
      return _EmptyCategory(
        category: _category,
        onBrowse: _loadInstalledApps,
        isPicking: _isLoadingApps,
      );
    }
    if (_installedApps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'لم يتم العثور على تطبيقات مستخدم قابلة للمشاركة.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    final apps = _installedApps.values.toList()
      ..sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: apps.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final app = apps[index];
        return _InstalledAppTile(
          app: app,
          selected: _selectedApps.contains(app.packageName),
          sizeLabel: _formatSize(app.apkSizes.fold<int>(0, (a, b) => a + b)),
          onChanged: (selected) => _toggleApp(app, selected),
        );
      },
    );
  }
}

class _SelectedFile {
  const _SelectedFile({
    required this.path,
    required this.name,
    required this.size,
    required this.category,
  });

  final String path;
  final String name;
  final int size;
  final _FileCategory category;
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final _FileCategory category;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${category.label}, $count',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 82,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.brandTint : AppColors.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? AppColors.brand : AppColors.line,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                category.icon,
                color: selected ? AppColors.brand : AppColors.muted,
                size: 21,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      category.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? AppColors.brandDark : AppColors.ink,
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 3),
                    Text(
                      '$count',
                      style: TextStyle(
                        color: AppColors.brand,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.file,
    required this.selected,
    required this.sizeLabel,
    required this.onChanged,
  });

  final _SelectedFile file;
  final bool selected;
  final String sizeLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? AppColors.brand : AppColors.line,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.brandTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  file.category.icon,
                  color: AppColors.brand,
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sizeLabel,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Checkbox(
                value: selected,
                onChanged: (value) => onChanged(value ?? false),
                activeColor: AppColors.brand,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstalledAppTile extends StatelessWidget {
  const _InstalledAppTile({
    required this.app,
    required this.selected,
    required this.sizeLabel,
    required this.onChanged,
  });

  final InstalledApp app;
  final bool selected;
  final String sizeLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final icon = app.iconBytes;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? AppColors.brand : AppColors.line,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox.square(
                  dimension: 44,
                  child: icon == null
                      ? Container(
                          color: AppColors.brandTint,
                          child: Icon(
                            Icons.android_rounded,
                            color: AppColors.brand,
                          ),
                        )
                      : Image.memory(
                          icon,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: AppColors.brandTint,
                            child: Icon(
                              Icons.android_rounded,
                              color: AppColors.brand,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      app.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${app.apkPaths.length} APK · $sizeLabel',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              Checkbox(
                value: selected,
                onChanged: (value) => onChanged(value ?? false),
                activeColor: AppColors.brand,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCategory extends StatelessWidget {
  const _EmptyCategory({
    super.key,
    required this.category,
    required this.onBrowse,
    required this.isPicking,
  });

  final _FileCategory category;
  final VoidCallback onBrowse;
  final bool isPicking;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.brandTint,
                shape: BoxShape.circle,
              ),
              child: Icon(category.icon, color: AppColors.brand, size: 32),
            ),
            const SizedBox(height: 15),
            Text(
              'لا توجد ملفات محددة',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 5),
            Text(
              'استعرض ${category.label} لإضافتها إلى قائمة الإرسال.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: isPicking ? null : onBrowse,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('استعراض الملفات'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerMessage extends StatelessWidget {
  const _PickerMessage({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.danger : AppColors.brand;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError ? AppColors.orangeTint : AppColors.brandTint,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
