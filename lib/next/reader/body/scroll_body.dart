part of '../reader_body.dart';

/// 上下滚动。进度用字符偏移：保存时取视口顶部对应的字符，恢复时再换算回滚动位置，所以改字号、延迟加载插图都不会跳位置。
class ScrollBody extends StatefulWidget {
  const ScrollBody({
    super.key,
    required this.chapter,
    required this.spanOf,
    this.spanOfHighlight,
    this.highlight,
    required this.style,
    required this.margin,
    this.paragraphSpacing = 0,
    this.title = '',
    this.headingAccent,
    required this.startOffset,
    required this.onOffset,
    required this.onEnd,
    required this.onNext,
    this.nextLabel = '下一章',
    required this.wrap,
    required this.onTapZone,
    this.menuOpen,
    required this.onMark,
    this.userHighlights = const [],
    this.onHighlightTap,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.onPullDown,
    this.marked,
    this.onUserInteract,
    this.showHeader = false,
  });

  final int tapZone;
  final int tapInvert;

  /// 在章首继续往下拉：加 / 取消书签；[marked] 是当前位置有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final VoidCallback? onUserInteract;
  final bool showHeader;
  final Chapter chapter;
  final SpanOf spanOf;
  final InlineSpan Function(int from, int to, (int, int)? hl)? spanOfHighlight;
  final ValueListenable<(int, int)?>? highlight;
  final TextStyle style;
  final double margin;
  final double paragraphSpacing;
  final List<HighlightEntry> userHighlights;
  final void Function(HighlightEntry)? onHighlightTap;

  /// 章节名，显示在正文开头
  final String title;
  final (Color, Widget Function(double width))? headingAccent;
  final int startOffset;
  final ValueChanged<int> onOffset;

  /// 滚到章末
  final VoidCallback onEnd;
  final VoidCallback? onNext;

  /// 章末按钮的字：全书最后一章是「读完了」
  final String nextLabel;
  final Widget Function(Widget) wrap;

  /// 点在空白处（切换菜单栏）
  final VoidCallback onTapZone;

  /// 菜单开着时点哪里都只收起菜单（[onTapZone]），不翻页、不点备注
  final bool Function()? menuOpen;
  final void Function(Mark) onMark;

  /// 朗读正在读的位置（字符偏移）：不在当前屏幕内时自动翻页 / 滚动过去
  final int? follow;
  final ReaderNav? nav;
  final bool Function() hasSelection;

  @override
  State<ScrollBody> createState() => _ScrollBodyState();
}

class _ScrollBodyState extends State<ScrollBody> {
  final _controller = ScrollController();
  final _textKey = GlobalKey();
  List<(int, int, GlobalKey)> _paraKeys = const [];
  String? _paraText;
  double _padTop = 0; // 正文第一行到滚动内容顶部的距离（含章节标题）
  DateTime _lastAutoReport = DateTime.fromMillisecondsSinceEpoch(0);

  void _syncParaKeys() {
    if (widget.paragraphSpacing <= 0) {
      _paraKeys = const [];
      _paraText = null;
      return;
    }
    final text = widget.chapter.text;
    if (identical(_paraText, text) && _paraKeys.isNotEmpty) return;
    _paraText = text;
    final ranges = splitParagraphRanges(text, 0, text.length);
    _paraKeys = [for (final (a, b) in ranges) (a, b, GlobalKey())];
  }

  double? _contentYForOffset(int offset) {
    final target = math.min(offset, widget.chapter.text.length);
    if (widget.paragraphSpacing <= 0) {
      final ro = _textKey.currentContext?.findRenderObject();
      if (ro is! RenderParagraph) return null;
      return _padTop + ro.getOffsetForCaret(TextPosition(offset: target), Rect.zero).dy;
    }
    if (_paraKeys.isEmpty) return null;
    final firstRo = _paraKeys.first.$3.currentContext?.findRenderObject();
    if (firstRo is! RenderBox) return null;
    final firstTopGlobal = firstRo.localToGlobal(Offset.zero).dy;
    for (final (a, b, key) in _paraKeys) {
      if (target <= b || identical(key, _paraKeys.last.$3)) {
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderParagraph) return null;
        final dy = ro.getOffsetForCaret(TextPosition(offset: (target - a).clamp(0, b - a)), Rect.zero).dy;
        return _padTop + (ro.localToGlobal(Offset.zero).dy - firstTopGlobal) + dy;
      }
    }
    return null;
  }

  void _followOffset(int f) {
    if (!mounted || !_controller.hasClients) return;
    final y = _contentYForOffset(f);
    if (y == null) return;
    final view = _controller.position;
    if (y < view.pixels || y > view.pixels + view.viewportDimension - 120) {
      _controller.animateTo((y - 80).clamp(0.0, view.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _onHighlight() {
    final hl = widget.highlight?.value;
    if (hl != null) _followOffset(hl.$1);
  }

  bool? _autoStep(double dy) {
    if (!mounted || !_controller.hasClients) return null;
    final pos = _controller.position;
    if (pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 1.5) {
      widget.onEnd();
      return false;
    }
    final next = (pos.pixels + dy).clamp(0.0, pos.maxScrollExtent);
    _controller.jumpTo(next);
    final now = DateTime.now();
    if (now.difference(_lastAutoReport) >= const Duration(milliseconds: 500) || next >= pos.maxScrollExtent - 1.5) {
      _lastAutoReport = now;
      widget.onOffset(_charAtTop());
    }
    if (next >= pos.maxScrollExtent - 1.5) {
      widget.onEnd();
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    widget.highlight?.addListener(_onHighlight);
    widget.nav
      ?..next = (() => _page(1))
      ..prev = (() => _page(-1))
      ..scrollBy = _nudge
      ..autoScrollStep = _autoStep
      ..toPage = null
      ..toFraction = ((f) {
        if (_controller.hasClients) _controller.jumpTo(f.clamp(0.0, 1.0) * _controller.position.maxScrollExtent);
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void didUpdateWidget(ScrollBody old) {
    super.didUpdateWidget(old);
    if (widget.highlight != old.highlight) {
      old.highlight?.removeListener(_onHighlight);
      widget.highlight?.addListener(_onHighlight);
    }
    final f = widget.follow;
    if (f != null && f != old.follow) _followOffset(f);
  }

  @override
  void dispose() {
    widget.highlight?.removeListener(_onHighlight);
    _controller.dispose();
    super.dispose();
  }

  void _nudge(double dy) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    _controller.animateTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent), duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
  }

  /// 滚一屏（留一点重叠）；已经到底再往后就去下一章。
  void _page(int dir) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    if (dir > 0 && p.pixels >= p.maxScrollExtent - 2) return widget.onNext?.call();
    _nudge(dir * p.viewportDimension * 0.9);
  }

  void _restore() {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final off = widget.startOffset;
    if (off >= kToEnd) {
      _controller.jumpTo(max);
      widget.onOffset(_charAtTop());
      return;
    }
    if (off > 0 && widget.chapter.text.trim().isEmpty && widget.chapter.images.isNotEmpty && max > 0) {
      final idx = (off - 1).clamp(0, widget.chapter.images.length - 1);
      _controller.jumpTo((idx / widget.chapter.images.length * max).clamp(0.0, max));
    } else if (off > 0) {
      final y = _contentYForOffset(off);
      if (y != null) _controller.jumpTo(y.clamp(0.0, max));
    }
    if (max <= 0 || _controller.position.pixels >= max - 40) widget.onEnd();
  }

  int _charAtTop() {
    if (widget.chapter.text.trim().isEmpty) {
      if (!_controller.hasClients || widget.chapter.images.isEmpty) return 0;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) return 0;
      final ratio = (_controller.position.pixels / max).clamp(0.0, 0.9999);
      return 1 + (ratio * widget.chapter.images.length).floor();
    }
    final top = (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy;
    if (widget.paragraphSpacing <= 0) {
      final ro = _textKey.currentContext?.findRenderObject();
      if (ro is! RenderParagraph) return 0;
      final y = top - ro.localToGlobal(Offset.zero).dy;
      return y <= 0 ? 0 : ro.getPositionForOffset(Offset(0, y)).offset;
    }
    for (final (a, _, key) in _paraKeys) {
      final ro = key.currentContext?.findRenderObject();
      if (ro is! RenderParagraph) continue;
      final pTop = ro.localToGlobal(Offset.zero).dy;
      if (pTop + ro.size.height < top) continue;
      final y = top - pTop;
      return y <= 0 ? a : a + ro.getPositionForOffset(Offset(0, y)).offset;
    }
    return 0;
  }

  int? _hitOffset(Offset global) {
    if (widget.paragraphSpacing <= 0) return _hitOffsetInKey(_textKey, 0, global);
    return _hitOffsetInKeys([for (final (a, _, k) in _paraKeys) (a, k)], global);
  }

  Widget _buildBodyText(Chapter c, (int, int)? hl) {
    final strut = readerStrut(widget.style);
    InlineSpan span(int a, int b) => widget.spanOfHighlight != null ? widget.spanOfHighlight!(a, b, hl) : widget.spanOf(a, b);
    if (widget.paragraphSpacing <= 0) {
      return material.Text.rich(span(0, c.text.length), key: _textKey, textScaler: TextScaler.noScaling, strutStyle: strut);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _paraKeys.length; i++)
          Padding(
            padding: i + 1 < _paraKeys.length ? EdgeInsets.only(bottom: widget.paragraphSpacing) : EdgeInsets.zero,
            child: material.Text.rich(span(_paraKeys[i].$1, _paraKeys[i].$2), key: _paraKeys[i].$3, textScaler: TextScaler.noScaling, strutStyle: strut),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chapter;
    _syncParaKeys();
    final hasText = c.text.trim().isNotEmpty;
    final width = MediaQuery.sizeOf(context).width - widget.margin * 2;
    final head = hasText ? headingHeight(widget.title, widget.style, width) : 0.0;
    final padTop = MediaQuery.viewPaddingOf(context).top + (widget.showHeader ? 36 : 24);
    _padTop = padTop + head;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          widget.onUserInteract?.call();
        } else if (n is ScrollEndNotification) {
          widget.onOffset(_charAtTop());
          if (n.metrics.maxScrollExtent <= 0 || n.metrics.pixels >= n.metrics.maxScrollExtent - 40) widget.onEnd();
        }
        return false;
      },
      child: TapDetector(
        hasSelection: widget.hasSelection,
        onTap: (local, size, global) {
          if (widget.menuOpen?.call() ?? false) {
            widget.onTapZone();
            return false;
          }
          final idx = _hitOffset(global);
          if (idx != null) {
            final m = _markAtOffset(c, idx);
            if (m != null) {
              widget.onMark(m);
              return false;
            }
            final h = _highlightAtOffset(widget.userHighlights, idx);
            if (h != null && widget.onHighlightTap != null) {
              widget.onHighlightTap!(h);
              return false;
            }
          }
          switch (tapActionAt(widget.tapZone, widget.tapInvert, local, size, paged: false)) {
            case TapAction.prev:
              widget.onUserInteract?.call();
              _page(-1);
            case TapAction.next:
              widget.onUserInteract?.call();
              _page(1);
            case TapAction.menu:
              widget.onTapZone();
              return false;
          }
          return true;
        },
        child: PullBookmark(
          onPull: widget.onPullDown,
          marked: widget.marked,
          color: widget.style.color ?? Colors.grey,
          top: MediaQuery.viewPaddingOf(context).top,
          child: widget.wrap(
          SingleChildScrollView(
            controller: _controller,
            padding: EdgeInsets.fromLTRB(widget.margin, padTop, widget.margin, MediaQuery.viewPaddingOf(context).bottom + 48), // 底部留出页脚的高度，别挡字
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (head > 0) chapterHeading(widget.title, widget.style, width, height: head, accent: widget.headingAccent),
                if (widget.highlight != null && widget.spanOfHighlight != null)
                  ValueListenableBuilder<(int, int)?>(
                    valueListenable: widget.highlight!,
                    builder: (_, hl, _) => _buildBodyText(c, hl),
                  )
                else
                  _buildBodyText(c, null),
                for (var idx = 0; idx < c.images.length; idx++) Padding(padding: const EdgeInsets.only(top: 16), child: _readerImageWidget(c.images[idx], widget.style.color, gallery: c.images, index: idx)),
                if (widget.onNext != null) Padding(padding: const EdgeInsets.only(top: 32), child: OutlinedButton(onPressed: widget.onNext, child: Text(widget.nextLabel))),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// 下拉加书签：往下拉时整页跟着手指往下移（越拉越沉），顶上露出一条，中间是书签图标和提示；
/// 拉过 [_threshold] 图标变实心、轻震一下，松手加 / 取消书签，页面带一点回弹缩回去。平时什么都不显示。
/// 翻页模式（[drag]）直接认竖向拖动；滚动模式只认滚到顶后继续往下拉（滚动视图的越界通知）。
class PullBookmark extends StatefulWidget {
  const PullBookmark({super.key, required this.child, required this.onPull, required this.marked, required this.color, required this.top, this.drag = false});

  final Widget child;
  final VoidCallback? onPull;
  final bool Function()? marked;
  final Color color;
  final double top; // 状态栏高度
  final bool drag;

  @override
  State<PullBookmark> createState() => _PullBookmarkState();
}

class _PullBookmarkState extends State<PullBookmark> with SingleTickerProviderStateMixin {
  static const _threshold = 72.0, _max = 120.0;
  double _pull = 0; // 手指拉下的距离（原始值）
  late final _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 380))..addListener(() => setState(() {}));
  double _from = 0; // 松手时露出的高度，回弹从这里开始

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  /// 页面实际下移的距离：越往下越拉不动
  double get _shown {
    if (_back.isAnimating) return _from * (1 - Curves.easeOutBack.transform(_back.value));
    return _pull <= 0 ? 0 : _max * (1 - math.exp(-_pull / _max));
  }

  void _update(double v) {
    if (_back.isAnimating) _back.stop();
    final was = _pull >= _threshold;
    setState(() => _pull = v.clamp(0, _max * 3));
    if (!was && _pull >= _threshold) HapticFeedback.mediumImpact();
  }

  void _release() {
    if (_pull <= 0) return;
    if (_pull >= _threshold) widget.onPull?.call();
    _from = _shown;
    _pull = 0;
    _back.forward(from: 0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _update(_pull - n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // iOS 回弹式滚动：顶部越界是负的 pixels；正常往下滚就收回
      n.metrics.pixels < 0 ? _update(-n.metrics.pixels) : (_pull > 0 ? _update(_pull - (n.scrollDelta ?? 0)) : null);
    } else if (n is ScrollEndNotification) {
      _release();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPull == null) return widget.child;
    final shown = _shown;
    final ready = _pull >= _threshold;
    final marked = widget.marked?.call() ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    final progress = (_pull / _threshold).clamp(0.0, 1.0);
    Widget child = Transform.translate(offset: Offset(0, shown), child: widget.child);
    child = widget.drag
        ? GestureDetector(
            supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}, // 鼠标拖动留给选字，触控板双指留给翻页
            onVerticalDragUpdate: (d) => _update(_pull + d.delta.dy),
            onVerticalDragEnd: (_) => _release(),
            onVerticalDragCancel: _release,
            child: child,
          )
        : NotificationListener<ScrollNotification>(onNotification: _onScroll, child: child);
    return Stack(
      children: [
        child,
        // 页面下移后露出来的那一条（画在页面上面：仿真翻页的页面不透明）
        if (shown > 1)
          Positioned(
            top: widget.top,
            left: 0,
            right: 0,
            height: math.max(0, shown),
            child: IgnorePointer(
              child: Opacity(
                opacity: (shown / 48).clamp(0.0, 1.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.scale(
                      scale: 0.8 + 0.25 * progress,
                      child: Icon(
                        ready ? (marked ? Icons.bookmark_remove : Icons.bookmark_added) : (marked ? Icons.bookmark : Icons.bookmark_add_outlined),
                        size: 26,
                        color: ready ? accent : widget.color.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ready ? (marked ? '松手取消书签' : '松手添加书签') : (marked ? '下拉取消书签' : '下拉添加书签'),
                      style: TextStyle(fontSize: 13, color: ready ? accent : widget.color.withValues(alpha: 0.55), fontWeight: ready ? FontWeight.w600 : null),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

