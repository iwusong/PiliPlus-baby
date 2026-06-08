import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class CachedPlayerFullscreenPage extends StatefulWidget {
  const CachedPlayerFullscreenPage({super.key, required this.entry});

  final BiliDownloadEntryInfo entry;

  @override
  State<CachedPlayerFullscreenPage> createState() =>
      _CachedPlayerFullscreenPageState();
}

class _CachedPlayerFullscreenPageState extends State<CachedPlayerFullscreenPage> {
  static const _speedOptions = <double>[0.5, 1.0, 1.25, 1.5, 2.0];
  static const _hideAfter = Duration(seconds: 2);

  late final PlPlayerController _player;
  VideoController? _videoController;
  final _showControls = true.obs;
  final _showSpeedPanel = false.obs;
  final _controlsLock = false.obs;
  final _lockIconVisible = true.obs;

  final RxDouble _brightnessValue = 0.0.obs;
  final RxBool _brightnessIndicator = false.obs;
  Timer? _brightnessTimer;

  int? _pointerId;
  Offset? _initialFocalPoint;
  _SideGesture? _sideGesture;

  Timer? _hideTimer;
  StreamSubscription<double>? _volumeListener;
  Timer? _seekCooldown;
  Timer? _sliderSeekDebounce;

  @override
  void initState() {
    super.initState();
    _player = PlPlayerController.getInstance();
    _initPlayer();
    _scheduleHide();
  }

  Future<void> _initPlayer() async {
    final entry = widget.entry;
    final cid = entry.source?.cid ?? entry.pageData?.cid;
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    await _player.setDataSource(
      FileSource(
        dir: entry.entryDirPath,
        typeTag: entry.typeTag!,
        isMp4: entry.mediaType == 1,
        hasDashAudio: entry.hasDashAudio,
      ),
      isVertical: entry.pageData?.isVertical ?? false,
      aid: entry.avid,
      cid: cid,
      autoplay: true,
    );

    await _player.play();

    _loadInitialBrightness();

    if (PlatformUtils.isMobile) {
      try {
        FlutterVolumeController.updateShowSystemUI(true);
        FlutterVolumeController.getVolume().then((res) {
          if (mounted && res != null) _player.volume.value = res;
        }).catchError((_) {});
        _volumeListener = FlutterVolumeController.addListener(
          _onSystemVolumeChanged,
          emitOnStart: false,
        );
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _videoController = _player.videoController;
      });
    }
  }

  void _onSystemVolumeChanged(double value) {
    if (!mounted) return;
    if (_player.volumeInterceptEventStream) return;
    _player.volume.value = value;
    if (Platform.isIOS) {
      _player.volumeIndicator.value = true;
      _player.volumeTimer?.cancel();
      _player.volumeTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) _player.volumeIndicator.value = false;
      });
    }
  }

  void _loadInitialBrightness() {
    final future = _player.setSystemBrightness
        ? ScreenBrightnessPlatform.instance.system
        : ScreenBrightnessPlatform.instance.application;
    future.then((res) {
      if (mounted) _brightnessValue.value = res;
    }).catchError((_) {});
  }

  Future<void> _setBrightness(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    _brightnessValue.value = clamped;
    try {
      if (Platform.isIOS || _player.setSystemBrightness) {
        await ScreenBrightnessPlatform.instance.setSystemScreenBrightness(
          clamped,
        );
      } else {
        await ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
          clamped,
        );
      }
    } catch (_) {}
    _brightnessIndicator.value = true;
    _brightnessTimer?.cancel();
    _brightnessTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _brightnessIndicator.value = false;
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _showControls.value = true;
    _showSpeedPanel.value = false;
    _lockIconVisible.value = true;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) {
        _showControls.value = false;
        _showSpeedPanel.value = false;
        _lockIconVisible.value = false;
      }
    });
  }

  void _toggleControls() {
    if (_controlsLock.value) {
      if (_lockIconVisible.value) {
        _lockIconVisible.value = false;
        _hideTimer?.cancel();
      } else {
        _lockIconVisible.value = true;
        _hideTimer?.cancel();
        _hideTimer = Timer(_hideAfter, () {
          if (mounted) _lockIconVisible.value = false;
        });
      }
      return;
    }
    if (_showControls.value) {
      _showControls.value = false;
      _showSpeedPanel.value = false;
      _lockIconVisible.value = false;
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  void _togglePlay() {
    if (_player.playerStatus.value.isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
    _scheduleHide();
  }

  void _doSeek(Duration target, {bool isSeek = false}) {
    if (_seekCooldown?.isActive == true) return;
    _sliderSeekDebounce?.cancel();
    _player.seekTo(target, isSeek: isSeek);
    if (_player.playerStatus.value.isPlaying) {
      _player.play();
    }
    _seekCooldown?.cancel();
    _seekCooldown = Timer(const Duration(milliseconds: 200), () {});
    _scheduleHide();
  }

  void _onSpeedTap(double speed) {
    _player.setPlaybackSpeed(speed);
    _scheduleHide();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_controlsLock.value) return;
    _pointerId = event.pointer;
    _sideGesture = null;
    _initialFocalPoint = event.localPosition;
    _hideTimer?.cancel();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointerId != event.pointer || _initialFocalPoint == null) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) return;

    final pos = event.localPosition;
    final delta = pos - _initialFocalPoint!;

    if (_sideGesture == null) {
      if (delta.distanceSquared < 4) return;
      final dx = delta.dx.abs();
      final dy = delta.dy.abs();
      if (dy <= 3 * dx) return;

      final sectionWidth = size.width / 3;
      if (pos.dx < sectionWidth) {
        _sideGesture = .left;
      } else if (pos.dx >= sectionWidth * 2) {
        _sideGesture = .right;
      } else {
        _sideGesture = null;
        return;
      }
      _initialFocalPoint = pos;
    }

    final moveDelta = event.localPosition - _initialFocalPoint!;

    if (_sideGesture == .left) {
      final level = size.height * 3;
      final next = _brightnessValue.value - moveDelta.dy / level;
      _setBrightness(next);
      _initialFocalPoint = event.localPosition;
      return;
    }

    if (_sideGesture == .right) {
      final maxV = PlPlayerController.maxVolume;
      final level = size.height * 0.5;
      final next = clampDouble(
        _player.volume.value - moveDelta.dy / level,
        0.0,
        maxV,
      );
      _player.setVolume(next);
      _initialFocalPoint = event.localPosition;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_pointerId != event.pointer) return;
    _pointerId = null;
    _initialFocalPoint = null;
    _sideGesture = null;
    if (_showControls.value) _scheduleHide();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_pointerId == null || _pointerId != event.pointer) return;
    _pointerId = null;
    _initialFocalPoint = null;
    _sideGesture = null;
  }

  Future<void> _onBack() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
    if (mounted) Get.back();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _brightnessTimer?.cancel();
    _volumeListener?.cancel();
    _volumeListener = null;
    _seekCooldown?.cancel();
    _sliderSeekDebounce?.cancel();
    if (PlatformUtils.isMobile) {
      try {
        FlutterVolumeController.removeListener();
      } catch (_) {}
    }
    _player.pause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            return Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: GestureDetector(
              onTap: _toggleControls,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                children: [
                  Center(
                    child: _videoController != null
                        ? Video(controller: _videoController!)
                        : const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                  ),
                  Obx(() {
                    if (!_showControls.value) return const SizedBox.shrink();
                    return _buildControls(constraints);
                  }),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Obx(() {
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _showControls.value
                            ? _buildTopBar()
                            : const SizedBox.shrink(),
                      );
                    }),
                  ),
                  _buildBrightnessIndicator(),
                  _buildVolumeIndicator(),
                  _buildLockButton(),
                ],
              ),
            ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      key: const ValueKey('topBar'),
      padding: const EdgeInsets.only(
        left: 8,
        right: 16,
        bottom: 6,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 20,
              ),
              onPressed: _onBack,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                widget.entry.showTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: .ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.entry.qualityPithyDescription,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(BoxConstraints constraints) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.35),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.55),
            ],
            stops: const [0.0, 0.25, 0.65, 1.0],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: const Alignment(0, 0.45),
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: _buildCenterControls(),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _buildBottomBar(),
              ),
            ),
            Obx(() {
              if (!_showSpeedPanel.value) return const SizedBox.shrink();
              return Positioned(
                right: 16,
                bottom: 16 + 100,
                child: SafeArea(
                  top: false,
                  child: _buildSpeedPanel(),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    return Obx(() {
      final isPlaying = _player.playerStatus.value.isPlaying;
      return Row(
        mainAxisAlignment: .center,
        mainAxisSize: .min,
        children: [
          _roundIcon(
            icon: Icons.replay_10,
            onTap: () {
              final pos = _player.position - const Duration(seconds: 10);
              _doSeek(pos < Duration.zero ? Duration.zero : pos);
            },
          ),
          const SizedBox(width: 24),
          _roundIcon(
            icon: isPlaying ? Icons.pause : Icons.play_arrow,
            size: 56,
            onTap: _togglePlay,
          ),
          const SizedBox(width: 24),
          _roundIcon(
            icon: Icons.forward_10,
            onTap: () {
              final pos = _player.position + const Duration(seconds: 10);
              final maxMs = _player.duration.value.inMilliseconds;
              final target = maxMs > 0 && pos.inMilliseconds > maxMs
                  ? Duration(milliseconds: maxMs)
                  : pos;
              _doSeek(target);
            },
          ),
        ],
      );
    });
  }

  Widget _roundIcon({
    required IconData icon,
    required VoidCallback onTap,
    double size = 48,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.5),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Obx(() {
                return Text(
                  _formatDuration(
                    Duration(seconds: _player.positionSeconds.value),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                );
              }),
              Expanded(child: _buildProgressBar()),
              Obx(() {
                return Text(
                  _formatDuration(_player.duration.value),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                );
              }),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [

              Obx(() {
                final v = _brightnessValue.value;
                final icon = v < 1.0 / 3.0
                    ? Icons.brightness_low
                    : v < 2.0 / 3.0
                        ? Icons.brightness_medium
                        : Icons.brightness_high;
                return Row(
                  mainAxisSize: .min,
                  children: [
                    Icon(icon, color: Colors.white70, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      '${(v * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(width: 16),
              Obx(() {
                final speed = _player.playbackSpeed;
                return _controlChip(
                  icon: Icons.speed,
                  label: '${speed}x',
                  active: _showSpeedPanel.value,
                  onTap: () {
                    _showSpeedPanel.value = !_showSpeedPanel.value;
                    if (_showSpeedPanel.value) {
                      _hideTimer?.cancel();
                    } else {
                      _scheduleHide();
                    }
                  },
                );
              }),
              const Spacer(),
              Obx(() {
                final v = _player.volume.value;
                final icon = v == 0
                    ? Icons.volume_off
                    : v < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up;
                return Row(
                  mainAxisSize: .min,
                  children: [
                    Icon(icon, color: Colors.white70, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      '${(v * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  void _onProgressDragStart(ThumbDragDetails details) {
    _hideTimer?.cancel();
    _seekCooldown?.cancel();
    _sliderSeekDebounce?.cancel();
    _player.onChangedSliderStart(details.timeStamp);
  }

  void _onProgressDragUpdate(ThumbDragDetails details) {
    _player.onUpdatedSliderProgress(details.timeStamp);
  }

  void _onProgressSeek(Duration duration) {
    _player
      ..onChangedSliderEnd()
      ..onChangedSlider(duration.inSeconds);
    _sliderSeekDebounce?.cancel();
    _sliderSeekDebounce = Timer(const Duration(milliseconds: 100), () {
      _player.seekTo(duration, isSeek: false);
      if (_player.playerStatus.value.isPlaying) {
        _player.play();
      }
      _scheduleHide();
    });
  }

  Widget _buildProgressBar() {
    return Obx(() {
      return ProgressBar(
        progress: Duration(seconds: _player.sliderPositionSeconds.value),
        buffered: Duration(seconds: _player.bufferedSeconds.value),
        total: Duration(seconds: _player.duration.value.inSeconds),
        progressBarColor: Colors.white,
        baseBarColor: const Color(0x33FFFFFF),
        bufferedBarColor: Colors.white54,
        thumbColor: Colors.white,
        thumbGlowColor: Colors.white24,
        barHeight: 3.5,
        thumbRadius: 7,
        thumbGlowRadius: 25,
        onDragStart: _onProgressDragStart,
        onDragUpdate: _onProgressDragUpdate,
        onSeek: _onProgressSeek,
      );
    });
  }

  Widget _buildSpeedPanel() {
    return Obx(() {
      final current = _player.playbackSpeed;
      return Material(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: .min,
            children: [
              for (final s in _speedOptions)
                InkWell(
                  onTap: () => _onSpeedTap(s),
                  child: Container(
                    width: 96,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: .center,
                    child: Text(
                      '${s == s.toInt() ? s.toInt().toString() : s.toStringAsFixed(2)}x',
                      style: TextStyle(
                        color: (current - s).abs() < 0.001
                            ? const Color(0xFF00AEEC)
                            : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildBrightnessIndicator() {
    return IgnorePointer(
      ignoring: true,
      child: Align(
        alignment: Alignment.center,
        child: Obx(() {
          final v = _brightnessValue.value;
          final icon = v < 1.0 / 3.0
              ? Icons.brightness_low
              : v < 2.0 / 3.0
                  ? Icons.brightness_medium
                  : Icons.brightness_high;
          return AnimatedOpacity(
            curve: Curves.easeInOut,
            opacity: _brightnessIndicator.value ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: const BoxDecoration(
                color: Color(0x88000000),
                borderRadius: BorderRadius.all(Radius.circular(64)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    '${(v * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildVolumeIndicator() {
    return IgnorePointer(
      ignoring: true,
      child: Align(
        alignment: Alignment.center,
        child: Obx(() {
          final v = _player.volume.value;
          final icon = v == 0.0
              ? Icons.volume_off
              : v < 0.5
                  ? Icons.volume_down
                  : Icons.volume_up;
          return AnimatedOpacity(
            curve: Curves.easeInOut,
            opacity: _player.volumeIndicator.value ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: const BoxDecoration(
                color: Color(0x88000000),
                borderRadius: BorderRadius.all(Radius.circular(64)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 4),
                  Text(
                    '${(v * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _controlChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: active
          ? Colors.white.withValues(alpha: 0.2)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: .min,
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleLock() {
    _controlsLock.value = !_controlsLock.value;
    if (_controlsLock.value) {
      _showControls.value = false;
      _lockIconVisible.value = true;
      _hideTimer?.cancel();
      _hideTimer = Timer(_hideAfter, () {
        if (mounted) _lockIconVisible.value = false;
      });
    } else {
      _lockIconVisible.value = false;
    }
  }

  Widget _buildLockButton() {
    return Obx(() {
      if (!_lockIconVisible.value && !_showControls.value) {
        return const SizedBox.shrink();
      }
      final locked = _controlsLock.value;
      return Positioned(
        right: 12,
        top: 0,
        bottom: 0,
        child: Center(
          child: GestureDetector(
            onTap: _toggleLock,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: locked
                    ? const Color(0xAAFFFFFF)
                    : const Color(0x44000000),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                locked ? Icons.lock : Icons.lock_open,
                color: locked ? Colors.black87 : Colors.white70,
                size: 20,
              ),
            ),
          ),
        ),
      );
    });
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = two(d.inMinutes.remainder(60));
    final s = two(d.inSeconds.remainder(60));
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}

enum _SideGesture { left, right }
