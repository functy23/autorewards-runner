/// MD3 主题与共享组件。
///
/// 遵循 Material Design 3 + Apple 设计规范：
/// - 颜色一律走 ColorScheme 角色 token（ColorScheme.fromSeed 生成）
/// - 卡片为 surfaceContainer tonal surface、无描边无阴影（深度靠色调）
/// - 层级靠字重/字号/间距表达，克制装饰（Apple: Craft / Simplicity）
library;

import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// UI 修订号：设置页改动影响 MaterialApp 级配置（如预测性返回转场）时递增，
/// 主入口监听它整体重建。
final ValueNotifier<int> uiRevision = ValueNotifier<int>(0);

const _seed = Color(0xFF3949AB); // indigo 种子色，light/dark 各生成一套完整 scheme

/// 沉浸式模糊顶栏（Apple 材质风格：半透明 + backdrop blur，内容从其下滚过）。
/// 无标题 —— App 名称按设计显示在主页大标题里，随内容滚动。
class BlurredAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BlurredAppBar({super.key, this.actions});

  final List<Widget>? actions;

  @override
  Size get preferredSize {
    final mac = _isMac();
    return Size.fromHeight(mac ? 40 : kToolbarHeight);
  }

  static bool _isMac() {
    return defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: _isMac() ? 40 : kToolbarHeight,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: cs.surface.withValues(alpha: 0.55),
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: ColoredBox(color: cs.surface.withValues(alpha: 0.35)),
        ),
      ),
      actions: actions,
    );
  }
}

ThemeData buildAppTheme(Brightness brightness, {bool predictiveBack = true}) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        // Android 预测性返回手势转场（可关）；macOS 保持 Cupertino 风格
        TargetPlatform.android: predictiveBack
            ? const PredictiveBackPageTransitionsBuilder()
            : const ZoomPageTransitionsBuilder(),
        TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
      },
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// 官方图标，按 macOS 默认图标的角度裁圆角。
///
/// macOS (Big Sur+) 应用图标网格为 824x824 居中、圆角 185（≈22.4%），
/// 官方形状是 G2 连续曲率（superellipse）；Flutter 用 [ContinuousRectangleBorder]
/// 近似连续圆角，半径取 0.30*尺寸 以在视觉上贴近系统效果。
class SquircleIcon extends StatelessWidget {
  const SquircleIcon({super.key, required this.asset, this.size = 28});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      clipBehavior: Clip.antiAlias,
      shape: ContinuousRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.30),
      ),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover),
    );
  }
}

/// 总览页状态小卡。
///
/// 显示真实任务状态：未配置 / 查询中… / 已完成 / 未完成。
/// 右侧带单任务执行按钮（图标、无文字）。
/// 不自带 Expanded —— 宽窄屏的排列方式（横排/竖排）由主页控制。
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.label,
    required this.asset,
    required this.configured,
    required this.done,
    this.loading = false,
    this.running = false,
    this.onRun,
  });

  final String label;
  final String asset; // 官方图标资产路径
  final bool configured;
  final bool? done; // null = 查询失败/未查询
  final bool loading;
  final bool running;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (statusText, statusColor, emphasized) = !configured
        ? ('未配置', cs.onSurfaceVariant, false)
        : loading
            ? ('查询中…', cs.onSurfaceVariant, false)
            : done == true
                ? ('已完成', cs.primary, true)
                : ('未完成', cs.onSurfaceVariant, false);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SquircleIcon(asset: asset, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                // 单任务执行按钮（图标、无文字）——常驻显示：
                // 本任务运行中转圈；其他任务运行中或不可用时置灰（不消失）
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    tooltip: null,
                    onPressed: running || onRun == null ? null : onRun,
                    icon: running
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: cs.primary))
                        : Icon(Icons.play_arrow_rounded,
                            size: 22,
                            color: running || onRun == null
                                ? cs.onSurfaceVariant.withValues(alpha: 0.35)
                                : cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              statusText,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: statusColor,
                    fontWeight:
                        emphasized ? FontWeight.w600 : FontWeight.w400,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
