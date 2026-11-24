import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerEnterEvent, PointerHoverEvent, PointerScrollEvent, PointerScrollInertiaCancelEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library.dart';
import 'pages/cover_picker_page.dart' show kCoverAspect;
import 'pages/volumes_page.dart' show volumeHeroShuttle;
import 'text.dart';
import 'volumes.dart' show volumeChangeForProvider;
import 'widgets.dart';

/// 展示页通用的平滑缓动曲线（起速干脆、落点柔和）。
const Curve kShelfEase = Cubic(0.2, 0.8, 0.2, 1.0);

/// 方向性遮罩滚筒切换：新内容按翻页方向从遮罩外滑入，旧内容从另一侧滑出，无透明度淡化。
/// 系统开启「减弱动态效果」时直接替换内容。
class MaskedRollSwitcher extends StatelessWidget {
  const MaskedRollSwitcher({
    super.key,
    required this.child,
    this.direction = 1,
    this.duration = const Duration(milliseconds: 380),
    this.delay = Duration.zero,
    this.alignment = Alignment.center,
  });

  final Widget child;

  /// 翻页方向：`>= 0` 向右/下一页（新字自下而上顶入），`< 0` 向左/上一页（新字自上而下落入）。
  final int direction;
  final Duration duration;

  /// 与主标题错峰滚入的延迟（如副标题延迟 45ms）。
  final Duration delay;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return ClipRect(child: Align(alignment: alignment, child: child));
    }
    final dir = direction < 0 ? -1.0 : 1.0;
    final totalMs = duration.inMilliseconds + delay.inMilliseconds;
    final start = totalMs > 0 && delay > Duration.zero ? (delay.inMilliseconds / totalMs).clamp(0.0, 0.6) : 0.0;
    final currentKey = child.key;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: totalMs),
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
        transitionBuilder: (w, animation) {
          final incoming = w.key == currentKey;
          return SlideTransition(
            position: animation.drive(_RollOffsetTween(dir: dir, incoming: incoming, start: start)),
            child: w,
          );
        },
        child: child,
      ),
    );
  }
}

class _RollOffsetTween extends Animatable<Offset> {
  const _RollOffsetTween({required this.dir, required this.incoming, required this.start});

  final double dir;
  final bool incoming;
  final double start;

  @override
  Offset transform(double t) {
    final p = incoming ? t : 1.0 - t;
    final span = 1.0 - start;
    final raw = span <= 0 ? 1.0 : ((p - start) / span).clamp(0.0, 1.0);
    final eased = kShelfEase.transform(raw);
    return Offset(0, incoming ? dir * 1.05 * (1.0 - eased) : -dir * 1.05 * eased);
  }
}

/// 立体书架的尺寸和每本书的摆法。
///
/// 滑动手感和卷册页（`VolumesPage`）一样，区别在摆法：卷册页是一叠书，后面的卷压在当前卷底下；
/// 这里是一架子的书，书和书之间留缝、左右各露出半本，两侧的书朝中间微微转过来。
abstract final class Shelf3DLayout {
  /// 封面下面那一块（位置指示、书名、进度、按钮）的高度。固定，切书时上下都不动。
  static double infoHeight(double textScale) => 66 + 86 * textScale;

  /// 封面上下给阴影留的空间
  static const _stagePad = 44.0;

  /// 封面宽度：按可用高度尽量放大，但不超过屏宽的 62%，左右还要各露出一截。
  static double coverWidth(double width, double stageHeight) =>
      math.min(math.min((stageHeight - _stagePad) * kCoverAspect, width * 0.62), 340.0).clamp(96.0, 340.0);

  /// 放封面的那一层的高度：封面加上下阴影
  static double stageHeight(double coverWidth) => coverWidth / kCoverAspect + _stagePad;

  /// 相邻两本书中心的距离：中间那本的一半 + 旁边那本（缩小、转过）的一半 + 一道缝
  static double step(double coverWidth) => coverWidth * 0.95;

  /// 离中间 [d] 本（可以是小数，滑动途中）的那本书：往旁边挪多少、缩多少、转多少、压多暗、多透明。
  static ({double dx, double scale, double angle, double shade, double opacity}) pose(double d, double coverWidth) {
    final a = d.abs();
    final near = math.min(a, 1.0);
    final far = math.max(a - 1, 0.0);
    return (
      // 第一本错开一整个身位，再往后的挨得紧一点（宽屏上能看到两三本）
      dx: d.sign * (step(coverWidth) * near + coverWidth * 0.42 * far),
      scale: 1 - 0.18 * near - 0.06 * math.min(far, 2.0),
      // 约 20°，右边的书向左转、左边的向右转，朝着中间
      angle: -d.clamp(-1.0, 1.0) * 0.34,
      shade: math.min(a, 1.5) * 0.22,
      opacity: (2.4 - a).clamp(0.0, 1.0),
    );
  }
}

/// 书架的「立体」显示方式：一次看一本，左右滑切书，点中间那本打开卷册页（封面直接飞过去）。
class Shelf3DView extends StatefulWidget {
  const Shelf3DView({
    super.key,
    required this.books,
    this.initialAid,
    this.onFocusChanged,
    required this.selected,
    required this.heroEnabled,
    required this.coverOf,
    required this.badgeOf,
    required this.subtitleOf,
    required this.actionOf,
    required this.onOpen,
    required this.onRead,
    required this.onToggleSelect,
  });

  final List<LibBook> books;

  /// 一开始停在哪本（上次停的位置）；找不到就停在第一本
  final String? initialAid;

  /// 停到另一本上时告诉外面，用来记住位置
  final ValueChanged<String>? onFocusChanged;
  final Set<String> selected;

  /// 只有当前标签页开 Hero：保活的相邻标签里同一本书也有这个 tag
  final bool heroEnabled;
  final String Function(LibBook book) coverOf;

  /// 封面右上角的角标（未读数、多选时的勾），没有就返回 null
  final Widget? Function(LibBook book) badgeOf;

  /// 书名下面那一行：连载状态、读到第几卷、未读几章
  final String Function(LibBook book) subtitleOf;

  /// 下面那个按钮：读过的「继续读」、没读过的「开始读」，[cid] 为空时按钮就是打开卷册页
  final ({String label, String? cid}) Function(LibBook book) actionOf;
  final void Function(LibBook book) onOpen;
  final void Function(LibBook book, String cid) onRead;
  final void Function(LibBook book) onToggleSelect;

  @override
  State<Shelf3DView> createState() => _Shelf3DViewState();
}

class _Shelf3DViewState extends State<Shelf3DView> with SingleTickerProviderStateMixin {
  int _cur = 0;
  int _dir = 1;
  PageController? _pc;
  double _fraction = 0;
  final _focus = FocusNode(debugLabel: 'shelf-3d');
  DateTime _lastScrollEvent = DateTime(0);
  DateTime _lastWheelStep = DateTime(0);
  double _wheelAccum = 0;
  double _lastAbsDelta = 0;
  bool _wheelLocked = false;
  double _lastCoverWidth = 0;
  final _precached = <String>{};
  int _lastPrecachedCur = -1;

  // 桌面端鼠标微交互：中央封面 3D 视差倾转 + 相邻封面悬停抬升（空闲时自动停帧，不耗电也不阻塞测试）
  late final Ticker _ticker = createTicker(_onTick);
  final _motion = ValueNotifier<int>(0);
  Duration _lastTick = Duration.zero;
  double _tiltX = 0, _tiltY = 0;
  double _targetTiltX = 0, _targetTiltY = 0;
  int? _hoveredIndex;
  final _lifts = <int, double>{};
  bool _reduceMotion = false;

  void _ensureTicking() {
    if (_reduceMotion) return;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _resetPointerMotion() {
    _hoveredIndex = null;
    _targetTiltX = 0;
    _targetTiltY = 0;
    if (_reduceMotion) {
      _tiltX = _tiltY = 0;
      _lifts.clear();
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_tiltX != 0 || _tiltY != 0 || _lifts.isNotEmpty) _ensureTicking();
  }

  void _onStageHover(PointerHoverEvent e, double stageW, double stageH, double coverW, double coverH) {
    if (e.kind != PointerDeviceKind.mouse || _reduceMotion) return;
    final dx = e.localPosition.dx - stageW / 2;
    final dy = e.localPosition.dy - stageH / 2;
    final settled = (_page - _cur).abs() < 0.3;
    final onCover = settled && dx.abs() <= coverW * 0.55 && dy.abs() <= coverH * 0.55;
    if (onCover) {
      _targetTiltY = -(dx / (coverW * 0.55)).clamp(-1.0, 1.0) * 0.105; // 约 ±6°
      _targetTiltX = (dy / (coverH * 0.55)).clamp(-1.0, 1.0) * 0.075; // 约 ±4.3°
    } else {
      _targetTiltY = -(dx / math.max(stageW, 1.0)).clamp(-0.5, 0.5) * 0.05;
      _targetTiltX = 0;
    }
    _ensureTicking();
  }

  void _onItemEnter(int i, PointerEnterEvent e) {
    if (e.kind != PointerDeviceKind.mouse || _reduceMotion) return;
    if (_hoveredIndex == i) return;
    _hoveredIndex = i;
    _lifts.putIfAbsent(i, () => 0);
    _ensureTicking();
  }

  void _onItemExit(int i) {
    if (_hoveredIndex != i) return;
    _hoveredIndex = null;
    if (_lifts.isNotEmpty) _ensureTicking();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? 1 / 60 : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;
    final tiltAlpha = 1 - math.exp(-7.0 * dt);
    final liftAlpha = 1 - math.exp(-12.0 * dt);
    final settled = (_page - _cur).abs() < 0.3;
    final tx = settled ? _targetTiltX : 0.0;
    final ty = settled ? _targetTiltY : 0.0;

    var active = false;
    _tiltX += (tx - _tiltX) * tiltAlpha;
    _tiltY += (ty - _tiltY) * tiltAlpha;
    if ((tx - _tiltX).abs() < 0.0005) {
      _tiltX = tx;
    } else {
      active = true;
    }
    if ((ty - _tiltY).abs() < 0.0005) {
      _tiltY = ty;
    } else {
      active = true;
    }

    final p = _page;
    final hov = _hoveredIndex;
    if (hov != null && (hov - p).abs() > 0.5) _lifts.putIfAbsent(hov, () => 0);
    final remove = <int>[];
    for (final entry in _lifts.entries.toList()) {
      final target = (hov == entry.key && (entry.key - p).abs() > 0.5) ? 1.0 : 0.0;
      var next = entry.value + (target - entry.value) * liftAlpha;
      if ((target - next).abs() < 0.001) {
        next = target;
      } else {
        active = true;
      }
      if (next == 0) {
        remove.add(entry.key);
      } else {
        _lifts[entry.key] = next;
      }
    }
    for (final k in remove) {
      _lifts.remove(k);
    }

    _motion.value++;
    if (!active) _ticker.stop();
  }

  void _precacheAround(int center) {
    if (!mounted || widget.books.isEmpty || _lastCoverWidth <= 0) return;
    _lastPrecachedCur = center;
    final size = Size(_lastCoverWidth, _lastCoverWidth / kCoverAspect);
    for (var d = 1; d <= 3; d++) {
      for (final idx in [center + d, center - d]) {
        if (idx < 0 || idx >= widget.books.length) continue;
        final url = widget.coverOf(widget.books[idx]);
        if (url.isEmpty || !_precached.add(url)) continue;
        NetImage.precache(context, url, size).ignore();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _cur = math.max(0, widget.books.indexWhere((b) => b.aid == widget.initialAid));
  }

  /// 一页的宽度要等于两本书中心的距离，手指拖多远书就走多远。屏宽变了（转屏、拖窗口）就换一个，停在同一本。
  PageController _controller(double fraction) {
    if (_pc != null && (fraction - _fraction).abs() < 0.005) return _pc!;
    final old = _pc;
    _fraction = fraction;
    _pc = PageController(viewportFraction: fraction, initialPage: _cur);
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return _pc!;
  }

  double get _page {
    final pc = _pc;
    return pc != null && pc.hasClients && pc.position.haveDimensions ? pc.page ?? _cur.toDouble() : _cur.toDouble();
  }

  @override
  void didUpdateWidget(Shelf3DView old) {
    super.didUpdateWidget(old);
    // 换了排序、筛选、加减了书：停在原来那本上；那本没了就停在原来的位置
    if (old.books.isEmpty || widget.books.isEmpty) return;
    final aid = old.books[_cur.clamp(0, old.books.length - 1)].aid;
    final i = widget.books.indexWhere((b) => b.aid == aid);
    final target = i >= 0 ? i : math.min(_cur, widget.books.length - 1);
    if (target == _cur) {
      if (!identical(old.books, widget.books)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _precacheAround(_cur);
        });
      }
      return;
    }
    _dir = target >= _cur ? 1 : -1;
    _cur = target;
    _lifts.clear();
    _hoveredIndex = null;
    widget.onFocusChanged?.call(widget.books[target].aid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pc?.hasClients == true) _pc!.jumpToPage(_cur);
      if (mounted) _precacheAround(_cur);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _motion.dispose();
    _pc?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int i) {
    final pc = _pc;
    if (pc == null || !pc.hasClients) return;
    final target = i.clamp(0, widget.books.length - 1);
    if (target == _cur) return;
    _dir = target > _cur ? 1 : -1;
    if (_reduceMotion) {
      pc.jumpToPage(target);
      return;
    }
    pc.animateToPage(
      target,
      duration: Duration(milliseconds: math.min(260 + 40 * (target - _cur).abs(), 600)),
      curve: Curves.easeOutCubic,
    );
  }

  void _tap(int i) {
    _focus.requestFocus(); // Mac 上点过一下之后方向键就能切书
    final book = widget.books[i];
    if (widget.selected.isNotEmpty) {
      widget.onToggleSelect(book);
    } else if (i == _cur) {
      widget.onOpen(book);
    } else {
      _go(i);
    }
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is PointerScrollInertiaCancelEvent) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
      return;
    }
    if (e is! PointerScrollEvent) return;
    final delta = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
    if (delta == 0) return;
    final now = DateTime.now();
    // 超过 140ms 无连续滚轮事件，视为新一次手势，解除 macOS 触控板惯性锁
    if (now.difference(_lastScrollEvent) > const Duration(milliseconds: 140)) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
    }
    _lastScrollEvent = now;
    if (_wheelAccum != 0 && delta.sign != _wheelAccum.sign) {
      _wheelAccum = 0;
      _wheelLocked = false;
    }
    final absDelta = delta.abs();
    if (_wheelLocked) {
      final reaccelerated = absDelta > _lastAbsDelta * 1.8 && absDelta >= 12;
      _lastAbsDelta = absDelta;
      if (!reaccelerated || now.difference(_lastWheelStep) < const Duration(milliseconds: 240)) return;
      _wheelLocked = false;
      _wheelAccum = 0;
    }
    _lastAbsDelta = absDelta;
    _wheelAccum += delta;
    if (_wheelAccum.abs() < 18) return;
    if (now.difference(_lastWheelStep) < const Duration(milliseconds: 220)) return;
    _lastWheelStep = now;
    _wheelLocked = true;
    final step = _wheelAccum > 0 ? 1 : -1;
    _wheelAccum = 0;
    _go(_cur + step);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(_cur + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(_cur - 1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _tap(_cur);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    if (books.isEmpty) return const SizedBox.shrink();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      if (reduceMotion) _resetPointerMotion();
    }
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    return LayoutBuilder(
      builder: (context, c) {
        final infoH = Shelf3DLayout.infoHeight(textScale);
        final height = c.maxHeight.isFinite ? c.maxHeight : 640.0;
        final w = Shelf3DLayout.coverWidth(c.maxWidth, math.max(200.0, height - infoH));
        // 封面按宽度定下来以后，多出来的高度上下平分（整组居中），不全堆在最下面
        final stageH = Shelf3DLayout.stageHeight(w);
        final canScroll = stageH + infoH > height + 1;
        final pc = _controller((Shelf3DLayout.step(w) / c.maxWidth).clamp(0.15, 0.95));
        final cur = _cur.clamp(0, books.length - 1);
        final widthChanged = (_lastCoverWidth - w).abs() > 8;
        if (widthChanged) {
          _lastCoverWidth = w;
          _precached.clear();
        }
        if (widthChanged || _lastPrecachedCur != cur) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _precacheAround(cur);
          });
        }
        return Focus(
          autofocus: true,
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onWheel,
            child: SingleChildScrollView(
              // 正常高度恰好一屏不拦截外层下拉刷新；矮窗/横屏超屏时允许滚动以免裁切底部主按钮
              physics: canScroll ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(key: const ValueKey('shelf-3d-stage'), height: stageH, child: _stage(pc, w, c.maxWidth, stageH)),
                    SizedBox(key: const ValueKey('shelf-3d-info'), height: infoH, child: _info(books[cur], cur, textScale)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _stage(PageController pc, double w, double stageW, double stageH) {
    final books = widget.books;
    final h = w / kCoverAspect;
    final persp = 1 / (w * 3.2);
    // 裁掉左右伸出去的书：TabBarView 切标签时不画到相邻标签上。上下不裁，封面的影子要完整
    return MouseRegion(
      onHover: (e) => _onStageHover(e, stageW, stageH, w, h),
      onExit: (_) => _resetPointerMotion(),
      child: ClipRect(
        clipper: const _SidesClipper(),
        child: Stack(
          alignment: Alignment.center,
          children: [
            ExcludeSemantics(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: Listenable.merge([pc, _motion]),
                  builder: (context, _) {
                    final p = _page;
                    final shown = [for (var i = math.max(0, p.floor() - 2); i <= math.min(books.length - 1, p.ceil() + 2); i++) i]
                      ..sort((a, b) => (b - p).abs().compareTo((a - p).abs())); // 远的先画，近的压在上面
                    return Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [for (final i in shown) _book(i, i - p, w, h, persp)]);
                  },
                ),
              ),
            ),
            PageView.builder(
              controller: pc,
              itemCount: books.length,
              // 不用 PageView 自带的一次一页：快速一甩能划过好几本，停下时再对齐到某一本
              pageSnapping: false,
              physics: const _FlingSnapPhysics(),
              onPageChanged: (i) {
                HapticFeedback.selectionClick(); // 每划过一本轻震一下
                setState(() {
                  if (i != _cur) _dir = i > _cur ? 1 : -1;
                  _cur = i;
                });
                if (_lifts.isNotEmpty || _tiltX != 0 || _tiltY != 0) _ensureTicking();
                widget.onFocusChanged?.call(books[i].aid);
                _precacheAround(i);
              },
              itemBuilder: (context, i) => Semantics(
                button: true,
                selected: widget.selected.contains(books[i].aid),
                label: books[i].shown,
                hint: hz(context, i == _cur ? '点击打开分卷，长按多选' : '点击切换到这本书'),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (e) => _onItemEnter(i, e),
                  onExit: (_) => _onItemExit(i),
                  child: GestureDetector(
                    key: ValueKey('shelf-3d-hit-${books[i].aid}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tap(i),
                    onLongPress: () => widget.onToggleSelect(books[i]),
                    onSecondaryTap: () => widget.onToggleSelect(books[i]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _book(int i, double d, double w, double h, double persp) {
    final book = widget.books[i];
    final pose = Shelf3DLayout.pose(d, w);
    final front = d.abs() < 0.5;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final badge = widget.badgeOf(book);
    final lift = _reduceMotion ? 0.0 : (_lifts[i] ?? 0.0);
    final t = (1 - d.abs()).clamp(0.0, 1.0);
    final frontWeight = t * t * (3 - 2 * t);
    final tiltX = _reduceMotion ? 0.0 : _tiltX * frontWeight;
    final tiltY = _reduceMotion ? 0.0 : _tiltY * frontWeight;
    final effShade = pose.shade * (1 - lift * 0.35);
    Widget cover = Consumer(
      builder: (context, ref, _) {
        ref.watch(volumeChangeForProvider(book.aid));
        return _Cover(
          url: widget.coverOf(book),
          decodeSize: Size(w, h),
          shade: effShade,
          selected: widget.selected.contains(book.aid),
          // 中间那本影子深一点，像被抽出来一点
          shadow: (dark ? 0.5 : 0.26) * (0.55 + 0.45 * (1 - math.min(d.abs(), 1.0))),
        );
      },
    );
    // 只有中间那本带 Hero：点开时这张封面飞到卷册页最前面那卷
    if (front) {
      cover = HeroMode(
        enabled: widget.heroEnabled,
        child: Hero(tag: 'vols:${book.aid}', flightShuttleBuilder: volumeHeroShuttle, child: cover),
      );
    }
    final matrix = Matrix4.identity()..setEntry(3, 2, persp);
    if (tiltX != 0) matrix.rotateX(tiltX);
    matrix.rotateY(pose.angle + tiltY);
    Widget card = Transform.translate(
      offset: Offset(pose.dx, -lift * h * 0.045),
      child: Transform(
        alignment: Alignment.center,
        transform: matrix,
        child: Transform.scale(
          scale: pose.scale * (1 + lift * 0.02),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                cover,
                if (badge != null) Positioned(top: 8, right: 8, child: badge),
              ],
            ),
          ),
        ),
      ),
    );
    if (pose.opacity < 0.999) card = Opacity(opacity: pose.opacity, child: card);
    return KeyedSubtree(key: ValueKey(book.aid), child: card);
  }

  Widget _info(LibBook book, int cur, double textScale) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = widget.books.length;
    final selecting = widget.selected.isNotEmpty;
    final selected = widget.selected.contains(book.aid);
    final action = widget.actionOf(book);
    // 按钮一直在：多选时是选中 / 取消，平时是继续读 / 开始读 / 打开。占位不变，切书时什么都不动
    final Widget button = selecting
        ? OutlinedButton.icon(
            key: ValueKey('select-${book.aid}-$selected'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 20)),
            onPressed: () => widget.onToggleSelect(book),
            icon: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 20),
            label: Text(selected ? '已选中' : '选中'),
          )
        : FilledButton.tonalIcon(
            key: ValueKey('action-${book.aid}'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 22)),
            onPressed: () => action.cid == null ? widget.onOpen(book) : widget.onRead(book, action.cid!),
            icon: Icon(action.cid == null ? Icons.auto_stories_outlined : Icons.play_arrow_rounded, size: 20),
            label: Text(action.label),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Center(
              child: n > 1 ? _Indicator(index: cur, count: n, onPick: (i) => _pc?.jumpToPage(i), onTapDot: _go) : null,
            ),
          ),
          const SizedBox(height: 14),
          // 书名只占一行：长短不一的书名不会把下面的字顶上顶下，按滑动方向在遮罩内滚入
          SizedBox(
            height: 26 * textScale,
            child: MaskedRollSwitcher(
              direction: _dir,
              child: Text(
                book.shown,
                key: ValueKey(book.aid),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w700, height: 1.3),
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 18 * textScale,
            child: MaskedRollSwitcher(
              direction: _dir,
              delay: const Duration(milliseconds: 45),
              child: Text(
                widget.subtitleOf(book),
                key: ValueKey(book.aid),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 42 * textScale,
            child: Center(
              child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: button),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一本书的封面：圆角、柔和的大阴影，离中间越远越暗；多选选中时描一圈主色。
/// 阴影、静态封面与动态暗化遮罩分层并用 RepaintBoundary 隔离，避免滑动每帧重绘模糊阴影和离屏光栅化封面。
class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.shade, required this.selected, required this.shadow, this.decodeSize});

  final String url;
  final double shade;
  final bool selected;
  final double shadow;
  final Size? decodeSize;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final baseShadow = Theme.of(context).brightness == Brightness.dark ? 0.5 : 0.26;
    final shadowOpacity = (shadow / baseShadow).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: shadowOpacity,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: baseShadow),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
            ),
          ),
        ),
        RepaintBoundary(child: CoverImage(url, decodeSize: decodeSize)),
        if (shade > 0.005)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              color: Colors.black.withValues(alpha: shade),
            ),
          ),
        if (selected)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
            ),
          ),
      ],
    );
  }
}

/// 第几本：书少（≤ 9 本）用一排可点击的小圆点，当前那颗拉长；书多用细滑块，可以拖着快速找书。
class _Indicator extends StatelessWidget {
  const _Indicator({required this.index, required this.count, required this.onPick, required this.onTapDot});

  final int index;
  final int count;
  final ValueChanged<int> onPick;
  final ValueChanged<int> onTapDot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (count <= 9) {
      return Row(
        key: const ValueKey('shelf-3d-dots'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              button: true,
              selected: i == index,
              label: hz(context, '第 ${i + 1} 本'),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey('shelf-3d-dot-$i'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTapDot(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 9),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      width: i == index ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(color: i == index ? scheme.primary : scheme.outlineVariant, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Row(
        children: [
          Expanded(
            child: ExcludeFocus(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: scheme.primary,
                  inactiveTrackColor: scheme.outlineVariant,
                  thumbColor: scheme.primary,
                  // 细轨道、小圆点，和卷册页的一样
                  trackHeight: 2,
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0, pressedElevation: 0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  key: const ValueKey('shelf-3d-slider'),
                  value: index.toDouble(),
                  max: count - 1.0,
                  divisions: count - 1,
                  label: hz(context, '第 ${index + 1} 本'),
                  onChanged: (x) => onPick(x.round()),
                ),
              ),
            ),
          ),
          Text(
            '${index + 1} / $count',
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

/// 只裁左右两边
class _SidesClipper extends CustomClipper<Rect> {
  const _SidesClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -size.height, size.width, size.height * 2);

  @override
  bool shouldReclip(_SidesClipper oldClipper) => false;
}

/// 甩得越快划过的书越多，松手后停在离惯性终点最近的那本上。
///
/// 轻轻一拨（够得上甩的速度）至少走一本；慢慢拖完松手，回到离得最近的那本。
class _FlingSnapPhysics extends ScrollPhysics {
  const _FlingSnapPhysics({super.parent});

  /// 甩出去的速度 × 这个秒数 ≈ 惯性能走的距离
  static const _glide = 0.32;

  @override
  _FlingSnapPhysics applyTo(ScrollPhysics? ancestor) => _FlingSnapPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if (position.outOfRange || position is! PageMetrics) return super.createBallisticSimulation(position, velocity);
    final page = position.viewportDimension * position.viewportFraction;
    if (page <= 0) return super.createBallisticSimulation(position, velocity);
    final now = position.pixels / page;
    double target;
    if (velocity.abs() < minFlingVelocity) {
      target = now.roundToDouble();
    } else {
      target = ((position.pixels + velocity * _glide) / page).roundToDouble();
      // 一拨至少走一本
      if (velocity > 0 && target <= now) target = now.floorToDouble() + 1;
      if (velocity < 0 && target >= now) target = now.ceilToDouble() - 1;
    }
    final to = (target * page).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((to - position.pixels).abs() < toleranceFor(position).distance) return null;
    return _GlideSimulation(from: position.pixels, to: to, velocity: velocity, tolerance: toleranceFor(position));
  }
}

/// 从当前位置指数减速滑到 [to]：开头的速度尽量接上手指松开时的速度，不会冲过头再弹回来。
class _GlideSimulation extends Simulation {
  _GlideSimulation({required double from, required this.to, required double velocity, super.tolerance}) : _gap = to - from {
    // 速度方向和要走的方向一致时，用松手速度算衰减快慢；反方向（拖过一半又往回）就用默认的
    final k = velocity * _gap > 0 ? velocity / _gap : 10.0;
    _k = k.clamp(6.0, 40.0);
  }

  final double to;
  final double _gap;
  late final double _k;

  @override
  double x(double time) => to - _gap * math.exp(-_k * time);

  @override
  double dx(double time) => _k * _gap * math.exp(-_k * time);

  @override
  bool isDone(double time) => (_gap * math.exp(-_k * time)).abs() < tolerance.distance;
}
