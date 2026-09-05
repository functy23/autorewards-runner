/// 带复制按钮的输入框。
///
/// 点击复制按钮 → 文本进剪贴板 → 按钮动态切换为对勾（缩放+淡入），1.5 秒后还原。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CopyableField extends StatefulWidget {
  const CopyableField({
    super.key,
    required this.controller,
    this.decoration,
    this.maxLines = 1,
    this.obscureText = false,
    this.style,
    this.keyboardType,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final int maxLines;
  final bool obscureText;
  final TextStyle? style;
  final TextInputType? keyboardType;

  @override
  State<CopyableField> createState() => _CopyableFieldState();
}

class _CopyableFieldState extends State<CopyableField> {
  bool _copied = false;
  Timer? _revertTimer;

  @override
  void dispose() {
    _revertTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.controller.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _revertTimer?.cancel();
    _revertTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.decoration ?? const InputDecoration();
    return TextField(
      controller: widget.controller,
      maxLines: widget.maxLines,
      obscureText: widget.obscureText,
      style: widget.style,
      keyboardType: widget.keyboardType,
      decoration: base.copyWith(
        suffixIcon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: Tween(begin: 0.6, end: 1.0).animate(anim),
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: IconButton(
            key: ValueKey(_copied),
            onPressed: _copy,
            tooltip: null,
            icon: Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 20,
            ),
            color: _copied ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
