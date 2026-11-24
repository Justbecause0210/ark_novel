part of '../reader_page.dart';

/// 加载态：允许轻触唤出顶栏，同时左上角常驻半透明返回键 + 中央章节名提示，避免慢网或无侧滑平台被困在转圈屏。
class _ReaderLoadingView extends StatelessWidget {
  const _ReaderLoadingView({
    required this.palette,
    required this.title,
    required this.showBack,
    required this.onTap,
    required this.onBack,
  });

  final ReaderPalette palette;
  final String title;
  final bool showBack;
  final VoidCallback onTap;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: palette.fg),
                if (title.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: palette.fg.withValues(alpha: 0.8))),
                ],
                const SizedBox(height: 6),
                Text('正在加载章节…', style: TextStyle(fontSize: 12.5, color: palette.fg.withValues(alpha: 0.55))),
              ],
            ),
          ),
        ),
      ),
      if (showBack) _ReaderFloatingBackButton(palette: palette, onPressed: onBack),
    ],
  );
}

class _ReaderFloatingBackButton extends StatelessWidget {
  const _ReaderFloatingBackButton({required this.palette, required this.onPressed});

  final ReaderPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 8,
    left: 8,
    child: SafeArea(
      bottom: false,
      child: IconButton(
        tooltip: hz(context, '返回'),
        style: IconButton.styleFrom(backgroundColor: palette.fg.withValues(alpha: 0.08), foregroundColor: palette.fg),
        icon: const Icon(Icons.arrow_back),
        onPressed: onPressed,
      ),
    ),
  );
}

/// 受限章节底部提示卡（未启用妙妙小工具或未取到正文时显示）。
class _ReaderLockedBanner extends StatelessWidget {
  const _ReaderLockedBanner({
    required this.palette,
    required this.accent,
    required this.bottomPad,
    required this.hasAddon,
    required this.unlockEnabled,
    required this.onRetry,
    required this.onOpenUnlockSettings,
  });

  final ReaderPalette palette;
  final Color accent;
  final double bottomPad;
  final bool hasAddon;
  final bool unlockEnabled;
  final VoidCallback onRetry;
  final VoidCallback onOpenUnlockSettings;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    right: 16,
    bottom: bottomPad + 44,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Material(
          color: Color.alphaBlend(palette.fg.withValues(alpha: 0.08), palette.bg),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: palette.fg.withValues(alpha: 0.16)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 20, color: palette.fg.withValues(alpha: 0.7)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    !hasAddon
                        ? '本章受网站版权限制无法直接读取，可在设置中了解「妙妙小工具」'
                        : (!unlockEnabled ? '「妙妙小工具」已关闭，开启后可尝试读取受限章节' : '扩展通道暂未取到本章（可能为纯插图章或接口不可用）'),
                    style: TextStyle(fontSize: 13, height: 1.4, color: palette.fg.withValues(alpha: 0.85)),
                  ),
                ),
                if (hasAddon && unlockEnabled)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
                    onPressed: onRetry,
                    child: const Text('重试'),
                  ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
                  onPressed: onOpenUnlockSettings,
                  child: Text(!hasAddon ? '去了解' : '去设置'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 跳转后的 5 秒悬浮撤销条（菜单收起时直接显示，一键返回跳转前位置）。
class _ReaderUndoJumpBanner extends StatelessWidget {
  const _ReaderUndoJumpBanner({
    super.key,
    required this.palette,
    required this.accent,
    required this.bottomPad,
    required this.label,
    required this.onReturn,
    required this.onDismiss,
  });

  final ReaderPalette palette;
  final Color accent;
  final double bottomPad;
  final String label;
  final VoidCallback onReturn;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    right: 16,
    bottom: bottomPad + 42,
    child: Center(
      child: Material(
        color: Color.alphaBlend(palette.fg.withValues(alpha: 0.1), palette.bg),
        elevation: 2,
        shadowColor: Colors.black26,
        shape: StadiumBorder(side: BorderSide(color: palette.fg.withValues(alpha: 0.18))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.undo_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              Flexible(
                child: GestureDetector(
                  onTap: onReturn,
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: palette.fg)),
                ),
              ),
              IconButton(
                tooltip: hz(context, '关闭'),
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: Icon(Icons.close, color: palette.fg.withValues(alpha: 0.65)),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 滚动模式页眉 / 页脚条：复用同一份百分比与剩余时间推导逻辑。
class _ReaderScrollChromeBar extends StatelessWidget {
  const _ReaderScrollChromeBar({
    super.key,
    required this.isHeader,
    required this.palette,
    required this.hasCustomBg,
    required this.margin,
    required this.edgePad,
    required this.leftField,
    required this.rightField,
    required this.chapterTitle,
    required this.bookTitle,
    required this.status,
    required this.pos,
    required this.chapter,
    required this.volumeProgress,
    required this.volumeEta,
  });

  final bool isHeader;
  final ReaderPalette palette;
  final bool hasCustomBg;
  final double margin;
  final double edgePad;
  final int leftField;
  final int rightField;
  final String chapterTitle;
  final String bookTitle;
  final ValueListenable<String> status;
  final ValueListenable<int> pos;
  final Chapter chapter;
  final double Function(double) volumeProgress;
  final String? Function(double)? volumeEta;

  @override
  Widget build(BuildContext context) {
    final padding = isHeader ? EdgeInsets.fromLTRB(margin, edgePad + 8, margin, 6) : EdgeInsets.fromLTRB(margin, 6, margin, edgePad + 8);
    return Positioned(
      left: 0,
      right: 0,
      top: isHeader ? 0 : null,
      bottom: isHeader ? null : 0,
      child: IgnorePointer(
        child: ColoredBox(
          color: palette.bg.withValues(alpha: hasCustomBg ? 0.82 : 1.0),
          child: Padding(
            padding: padding,
            child: ValueListenableBuilder<int>(
              valueListenable: pos,
              builder: (_, currentPos, _) {
                final len = chapter.text.length;
                final imgs = chapter.images.length;
                final frac = len > 0 ? (currentPos / len).clamp(0.0, 1.0) : (imgs > 1 && currentPos > 0 ? ((currentPos - 1) / (imgs - 1)).clamp(0.0, 1.0) : 0.0);
                final volPct = (volumeProgress(frac) * 100).floor();
                final needEta = leftField == ReaderChromeField.volumeEta || rightField == ReaderChromeField.volumeEta;
                return ReaderChromeRow(
                  leftField: leftField,
                  rightField: rightField,
                  style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.5)),
                  chapterTitle: chapterTitle,
                  bookTitle: bookTitle,
                  status: status,
                  pageProgress: '本章 ${(frac * 100).floor()}% · 本卷 $volPct%',
                  volumeEta: needEta ? (volumeEta?.call(frac) ?? '本卷 $volPct%') : '',
                  volumeProgressText: '本卷 $volPct%',
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 自由划线摘录编辑弹窗（选色、写笔记、复制原文或删除）。
Future<({String action, String note, int color})?> _showHighlightEditDialog(BuildContext context, HighlightEntry entry) async {
  final controller = TextEditingController(text: entry.note);
  var colorIdx = entry.color;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setLocal) => AlertDialog(
        title: const Text('划线摘录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: Color(kHighlightColors[colorIdx]).withValues(alpha: 0.14),
                  border: Border(left: BorderSide(color: Color(kHighlightColors[colorIdx]), width: 3)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(entry.quote, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.45)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                children: [
                  for (var i = 0; i < kHighlightColors.length; i++)
                    GestureDetector(
                      onTap: () => setLocal(() => colorIdx = i),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(kHighlightColors[i]),
                          border: Border.all(color: colorIdx == i ? Theme.of(dialogCtx).colorScheme.onSurface : Colors.transparent, width: 2.2),
                        ),
                        child: colorIdx == i ? const Icon(Icons.check, size: 15, color: Colors.white) : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(hint: Text('写下这段句子的想法或笔记（可选）', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, 'delete'), child: const Text('删除')),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: entry.quote));
              Navigator.pop(dialogCtx, 'copied');
            },
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogCtx, 'save'), child: const Text('保存')),
        ],
      ),
    ),
  );
  final note = controller.text.trim();
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  if (action == null) return null;
  return (action: action, note: note, color: colorIdx);
}
