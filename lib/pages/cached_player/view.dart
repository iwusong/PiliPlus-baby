import 'dart:io';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/cached_player/controller.dart';
import 'package:PiliPlus/pages/cached_player/fullscreen_player.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:flutter/material.dart' hide SliverGridDelegateWithMaxCrossAxisExtent;
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class CachedPlayerListPage extends StatefulWidget {
  const CachedPlayerListPage({super.key});

  @override
  State<CachedPlayerListPage> createState() => _CachedPlayerListPageState();
}

class _CachedPlayerListPageState extends State<CachedPlayerListPage> {
  final _controller = Get.put(CachedPlayerListController());
  int _homeTapCount = 0;
  DateTime _lastHomeTap = DateTime(2000);

  void _onHomeTap() {
    final now = DateTime.now();
    if (now.difference(_lastHomeTap) > const Duration(seconds: 1)) {
      _homeTapCount = 0;
    }
    _lastHomeTap = now;
    _homeTapCount++;
    if (_homeTapCount >= 5) {
      _homeTapCount = 0;
      Get.offNamed('/mainApp');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已缓存视频'),
        actions: [
          IconButton(
            tooltip: '回到主页',
            onPressed: _onHomeTap,
            icon: const Icon(Icons.home_outlined),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Obx(() {
          if (_controller.list.isEmpty) {
            return CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: HttpError(
                    isSliver: false,
                    errMsg: '还没有缓存的视频',
                    onReload: _controller.load,
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Style.safeSpace,
                vertical: 8,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double availableWidth = constraints.maxWidth;
                  const double spacing = 10.0;
                  double minCardWidth = Grid.smallCardWidth * 1.2;
                  int crossAxisCount =
                      (availableWidth / minCardWidth).floor();
                  crossAxisCount = crossAxisCount.clamp(1, 5);
                  final double cardWidth =
                      (availableWidth - (crossAxisCount - 1) * spacing) /
                      crossAxisCount;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final entry in _controller.list)
                        SizedBox(
                          width: cardWidth,
                          child: _VideoCard(
                            entry: entry,
                            onTap: () => _openPlayer(entry),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          );
        }),
      ),
    );
  }

  void _openPlayer(BiliDownloadEntryInfo entry) {
    HapticFeedback.lightImpact();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    Get.to<void>(
      CachedPlayerFullscreenPage(entry: entry),
    )?.whenComplete(() {
      if (Platform.isAndroid || Platform.isIOS) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
      if (mounted) setState(() {});
    });
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.entry, required this.onTap});

  final BiliDownloadEntryInfo entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationMs = entry.totalTimeMilli;
    final durationText = _formatDuration(durationMs);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: Style.mdRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: Style.aspectRatio16x9,
              child: Stack(
                fit: .expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) => NetworkImgLayer(
                      src: entry.cover,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      borderRadius: .zero,
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        durationText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary
                            .withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        entry.qualityPithyDescription,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: [
                  Text(
                    entry.showTitle,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: .ellipsis,
                  ),
                  Text(
                    '${CacheManager.formatSize(entry.totalBytes)}'
                    '${entry.ownerName != null ? ' · ${entry.ownerName}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '--:--';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }
}
