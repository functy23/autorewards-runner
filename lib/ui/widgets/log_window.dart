/// 主页日志窗口 —— 移植 aShellYou logcat 的行设计：
///
/// 行：[ 4dp 级别色条 撑满行高 ] [ tag 紧跟 ] [ message 占满剩余宽度 ]
///   无圆角、无行间距，背景 = 级别色 10% 透明度，整行连续铺排
///   默认单行省略，点击展开全文（AnimatedSize 200ms），再点收起
/// 级别色：D 浅蓝 / I 绿 / W 琥珀 / E 红 / V 灰；暗色用原色、亮色向黑 lerp 45%
/// 消息正文固定 onSurface 87% 透明度（与 aShellYou 一致）
///
/// 两种形态（[scrollable]）：
/// - false（默认，竖屏主页）：行直接铺在父级滚动布局里随主页滚动。
///   ⚠️ 此形态不能放进无界高度的上下文，也不能在父级再有 ListView。
/// - true（平板三列窗口）：内部自带 ListView + 控制器，占据外部 Expanded
///   给出的有限高度，自动滚动到底部（上滑暂停，FAB 恢复）。
/// [tags] 非空时只显示命中 tag 的日志（null/空 = 全部）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/app_log.dart';

class LogWindow extends StatefulWidget {
  const LogWindow({
    super.key,
    this.tags,
    this.scrollable = false,
  });

  /// 只显示这些 tag 的日志（WB/MHY/BING/BING-JS…）；null = 不过滤
  final Set<String>? tags;

  /// true = 自带滚动（需要外部有限高度）；false = 行内联铺开随主页滚动
  final bool scrollable;

  @override
  State<LogWindow> createState() => _LogWindowState();
}

class _LogWindowState extends State<LogWindow> {
  List<LogLine> _lines = [];
  // 按行对象（AppLog 缓冲里的同一实例）记录展开态，避免过滤后索引错位
  final Set<LogLine> _expanded = <LogLine>{};
  bool _capturing = true;
  StreamSubscription<LogLine>? _sub;

  // —— 仅 scrollable 模式使用 ——
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;

  bool get _scrollable => widget.scrollable;

  List<LogLine> get _visibleLines {
    final t = widget.tags;
    if (t == null || t.isEmpty) return _lines;
    return _lines.where((l) => t.contains(l.tag)).toList();
  }

  @override
  void initState() {
    super.initState();
    _lines = AppLog.lines;
    _sub = AppLog.stream.listen((_) {
      if (!mounted || !_capturing) return;
      setState(() => _lines = AppLog.lines);
      if (_scrollable && _autoScroll) _scrollToBottom();
    });
    if (_scrollable) _scrollToBottom();
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_scrollable) _scroll.dispose();
    super.dispose();
  }

  /// 跳到底部（帧后执行）。hasClients 为 true 时滚动维度也可能尚未解析
  /// （首帧/上级布局被打断），此时读 maxScrollExtent 会空指针，
  /// 必须同时检查 hasContentDimensions。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // aShellYou LogLevelColors 调色板
  Color _levelBase(String level) => switch (level.trim()) {
        'DEBUG' => const Color(0xFF4FC3F7),
        'INFO' => const Color(0xFF81C784),
        'WARN' => const Color(0xFFFFB74D),
        'ERROR' => const Color(0xFFE57373),
        _ => const Color(0xFF9E9E9E),
      };

  Widget _row(LogLine line) {
    return _LogRow(
      line: line,
      expanded: _expanded.contains(line),
      baseColor: _levelBase(line.level),
      isDark: Theme.of(context).brightness == Brightness.dark,
      onTap: () => setState(() {
        _expanded.contains(line) ? _expanded.remove(line) : _expanded.add(line);
      }),
    );
  }

  Widget _emptyPlaceholder(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('暂无日志',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 工具行（安静、无卡片）----
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 4),
              Text('日志',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: cs.onSurfaceVariant)),
              const Spacer(),
              _toolIcon(
                context,
                icon:
                    _capturing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                onTap: () => setState(() => _capturing = !_capturing),
              ),
              _toolIcon(
                context,
                icon: Icons.copy_rounded,
                onTap: () async {
                  final text = _visibleLines.map((l) => l.formatted).join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('日志已复制到剪贴板')));
                },
              ),
              _toolIcon(
                context,
                icon: Icons.close_rounded,
                onTap: () => setState(() {
                  _lines = const [];
                  _expanded.clear();
                }),
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        // ---- 日志主体 ----
        if (!_scrollable) ...[
          // 行内联铺开，随主页滚动（ListView 塞进滚动结构会触发
          // RenderViewport 的 intrinsic 断言，见 BUILD_NOTES A.9）
          if (_visibleLines.isEmpty)
            _emptyPlaceholder(theme)
          else
            Column(children: [for (final l in _visibleLines) _row(l)]),
        ] else ...[
          Expanded(
            child: Stack(
              children: [
                if (_visibleLines.isEmpty)
                  Align(
                    alignment: Alignment.topCenter,
                    child: _emptyPlaceholder(theme),
                  )
                else
                  NotificationListener<UserScrollNotification>(
                    onNotification: (n) {
                      if (n.direction == ScrollDirection.reverse && _autoScroll) {
                        setState(() => _autoScroll = false);
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: _visibleLines.length,
                      itemBuilder: (_, i) => _row(_visibleLines[i]),
                    ),
                  ),
                if (!_autoScroll)
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      onPressed: () {
                        setState(() => _autoScroll = true);
                        if (_scroll.hasClients &&
                            _scroll.position.hasContentDimensions) {
                          _scroll.jumpTo(_scroll.position.maxScrollExtent);
                        }
                      },
                      child: const Icon(Icons.arrow_downward_rounded),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _toolIcon(BuildContext context,
      {required IconData icon, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
      color: cs.onSurfaceVariant,
    );
  }
}

/// aShellYou LogEntryRow 的 Flutter 版：
/// [4dp 色条] | [tag 列 flex3] | [message 列 flex7]，无圆角无间距
class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.line,
    required this.expanded,
    required this.baseColor,
    required this.isDark,
    required this.onTap,
  });

  final LogLine line;
  final bool expanded;
  final Color baseColor;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // aShellYou：暗色直接用粉彩原色，亮色向黑 lerp 45%
    final levelColor =
        isDark ? baseColor : Color.lerp(baseColor, Colors.black, 0.45)!;
    final messageColor = theme.colorScheme.onSurface.withValues(alpha: 0.87);
    final maxLines = expanded ? null : 1;

    final tagStyle = TextStyle(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w600,
      fontSize: 11,
      height: 14 / 11,
      color: levelColor,
    );
    final messageStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11,
      height: 14 / 11,
      color: messageColor,
    );

    return InkWell(
      onTap: onTap,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Container(
          color: baseColor.withValues(alpha: 0.10),
          // tag 紧跟色条（不再用 flex 列占宽，消除文本前的成段空白）；
          // IntrinsicHeight 让 4dp 色条撑满多行行高
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: baseColor),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(line.tag, style: tagStyle, maxLines: maxLines,
                      overflow: expanded ? null : TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                    child: Text(
                      '${line.timeText} ${line.message}',
                      style: messageStyle,
                      maxLines: maxLines,
                      overflow: expanded ? null : TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
