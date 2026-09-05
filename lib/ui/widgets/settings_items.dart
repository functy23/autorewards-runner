/// aShellYou 风格设置组件（移植自其 settings-dsl 设计 token）：
///
/// - 分组标题：labelLarge + primary 色，左缩进 31，上 24 下 8
/// - 卡片组（连体圆角）：单个 24 / 首个上 24 下 4 / 中间 4 / 末个上 4 下 24，
///   卡片间距 1，背景 surfaceContainer、无描边无阴影
/// - 条目：行内边距 17、列间距 17；前导图标为 primaryContainer 圆形底 +
///   10dp 内边距的 20dp 图标；标题 titleMedium 加粗，描述 bodySmall 70% 透明度
/// - 开关条目整卡可点；禁用时整体 50% 透明度
library;

import 'package:flutter/material.dart';

/// 按压缩放反馈（移植 aShellYou CustomCard 的 pressedScale，Apple: 反馈在
/// pointer-down 即时出现，scale 0.98）
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child});

  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 分组标题
class SettingsGroupHeader extends StatelessWidget {
  const SettingsGroupHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 31, top: 24, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

/// 连体圆角卡片组：子项按位置自动分配圆角（首 24/4，中 4，末 4/24，单个 24）
class SettingsCardGroup extends StatelessWidget {
  const SettingsCardGroup({super.key, required this.children});

  final List<Widget> children;

  BorderRadius _radiusFor(int index, int size) {
    const big = 24.0;
    const small = 4.0;
    if (size == 1) return const BorderRadius.all(Radius.circular(big));
    if (index == 0) {
      return const BorderRadius.vertical(
          top: Radius.circular(big), bottom: Radius.circular(small));
    }
    if (index == size - 1) {
      return const BorderRadius.vertical(
          top: Radius.circular(small), bottom: Radius.circular(big));
    }
    return const BorderRadius.all(Radius.circular(small));
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainer;
    return Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 1),
          PressableScale(
            child: Material(
              color: bg,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: _radiusFor(i, children.length)),
              child: children[i],
            ),
          ),
        ],
      ],
    );
  }
}

/// 条目前导图标：primaryContainer 圆形底 + 10dp 内边距的 20dp 图标
class ItemLeadingIcon extends StatelessWidget {
  const ItemLeadingIcon(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
      padding: const EdgeInsets.all(10),
      child: Icon(icon, size: 20, color: cs.onPrimaryContainer),
    );
  }
}

/// 条目正文（标题 + 可选描述）
class _ItemTexts extends StatelessWidget {
  const _ItemTexts({required this.title, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (description != null && description!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              description!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.9)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 开关条目（整卡可点，M3 Switch）
class SettingsSwitchItem extends StatelessWidget {
  const SettingsSwitchItem({
    super.key,
    required this.title,
    this.description,
    this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Row(
          children: [
            if (icon != null) ...[ItemLeadingIcon(icon!), const SizedBox(width: 17)],
            _ItemTexts(title: title, description: description),
            const SizedBox(width: 12),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// 可点击条目（trailing 自定义，如箭头/文本）
class SettingsTapItem extends StatelessWidget {
  const SettingsTapItem({
    super.key,
    required this.title,
    this.description,
    this.icon,
    this.trailing,
    required this.onTap,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Row(
          children: [
            if (icon != null) ...[ItemLeadingIcon(icon!), const SizedBox(width: 17)],
            _ItemTexts(title: title, description: description),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// 无交互内容条目（如输入框所在卡片、说明卡片）
class SettingsContentItem extends StatelessWidget {
  const SettingsContentItem({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(17), child: child);
  }
}

/// 纯状态展示条目：无开关、无点击（如账号组的「已配置/未配置」状态行）
class SettingsStatusItem extends StatelessWidget {
  const SettingsStatusItem({
    super.key,
    required this.title,
    this.description,
    this.icon,
  });

  final String title;
  final String? description;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(17),
      child: Row(
        children: [
          if (icon != null) ...[ItemLeadingIcon(icon!), const SizedBox(width: 17)],
          _ItemTexts(title: title, description: description),
        ],
      ),
    );
  }
}
