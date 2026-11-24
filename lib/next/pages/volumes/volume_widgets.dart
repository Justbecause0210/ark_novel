part of '../volumes_page.dart';

/// 叠在一起的卷封面：最前面的最大，越往两边越小、越往后压，越暗。
/// 封面自己画（按离当前页的距离排先后），上面盖一层透明的 PageView 只管滑动和点击。
class _Carousel extends StatelessWidget {
  const _Carousel({
    required this.aid,
    required this.vols,
    required this.controller,
    required this.page,
    required this.cur,
    required this.intro,
    required this.coverOf,
    required this.onPage,
    required this.onCoverSize,
    required this.onTap,
    required this.onLongPress,
    required this.coverKey,
  });

  final String aid;
  final List<Vol> vols;
  final PageController controller;
  final double Function() page;
  final int cur;
  final Animation<double> intro;
  final String Function(Vol) coverOf;
  final ValueChanged<int> onPage;
  final ValueChanged<Size> onCoverSize;
  final void Function(int, Vol) onTap;
  final ValueChanged<Vol> onLongPress;
  final GlobalKey coverKey;

  @override
  Widget build(BuildContext context) {
    final done = Volumes.done(aid);
    final read = ReadState.readView(aid);
    final reading = readingVolume(aid);
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight * 0.92;
        final w = math.min(h * kCoverAspect, c.maxWidth * 0.72);
        onCoverSize(Size(w, w / kCoverAspect));
        final route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
        return Stack(
          alignment: Alignment.center,
          children: [
            ExcludeSemantics(
              child: AnimatedBuilder(
                animation: Listenable.merge([controller, route, intro]),
                builder: (context, _) {
                  final p = page();
                  // 打开：书架那叠飞过来的时候其他卷先不画，飞到位后从书架上露边的位置往右抽出来（[stackPose]）；
                  // 返回时原地很快淡出（往中间收会在封面飞走后露出来）
                  final closing = route.status == AnimationStatus.reverse;
                  final flying = route.status == AnimationStatus.forward;
                  final q = closing ? 1.0 : Curves.easeOutCubic.transform(intro.value);
                  final fade = closing ? const Interval(0.6, 1).transform(route.value) : 1.0;
                  final edges = stackEdges(vols.length);
                  final shown = [for (var i = math.max(0, p.floor() - 3); i <= math.min(vols.length - 1, p.ceil() + 3); i++) i]
                    ..sort((a, b) => (b - p).abs().compareTo((a - p).abs())); // 远的先画，近的压在上面
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      for (final i in shown)
                        Builder(
                          key: ValueKey('$i:${vols[i].title}'),
                          builder: (context) {
                            final d = i - p;
                            final a = d.abs();
                            // 第一张错开大半个身位，再往后的只露一条边
                            final dx = d.sign * (w * 0.55 * math.min(a, 1) + w * 0.16 * math.max(a - 1, 0));
                            final v = vols[i];
                            final untouched = !v.cids.any(read.contains);
                            // 最前面那卷是飞过来的封面，不用抽；后面的从露边的位置出发，露不出边的藏在封面后面淡入
                            final k = i - cur;
                            final from = i == cur ? null : stackPose(math.min(math.max(k, 0), edges), w);
                            double lerp(double a, double b) => from == null ? b : a + (b - a) * q;
                            final shade = math.min(a, 1.5) * 0.3;
                            final card = RepaintBoundary(
                              child: _VolumeCard(
                                url: coverOf(v),
                                width: w,
                                done: done.containsKey(v.title),
                                reading: i == reading,
                                untouched: from == null && untouched,
                                shade: lerp(from?.dim ?? 0, shade + (from != null && untouched ? 0.2 : 0)),
                              ),
                            );
                            final show = from == null ? 1.0 : (flying ? 0.0 : (k >= 1 && k <= edges ? 1.0 : q));
                            final effOpacity = (3.2 - a).clamp(0.0, 1.0) * show * (i == cur ? 1.0 : fade);
                            Widget item = Transform.translate(
                              offset: Offset(lerp(from?.dx ?? 0, dx), 0),
                              child: Transform.scale(
                                scale: lerp(from?.scale ?? 1, 1 - 0.14 * math.min(a, 2.5)),
                                child: i == cur
                                    // key 包在 Hero 外面：放里面会被飞行动画复制一份，同一个 GlobalKey 出现两次就红屏
                                    ? KeyedSubtree(
                                        key: coverKey,
                                        child: Hero(tag: 'vols:$aid', flightShuttleBuilder: volumeHeroShuttle, child: card),
                                      )
                                    : card,
                              ),
                            );
                            if (effOpacity < 0.999) item = Opacity(opacity: effOpacity, child: item);
                            return item;
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
            PageView.builder(
              controller: controller,
              itemCount: vols.length,
              onPageChanged: onPage,
              itemBuilder: (context, i) => Semantics(
                button: true,
                selected: i == cur,
                label: vols[i].title,
                hint: hz(context, i == cur ? '点击开始阅读，长按换封面' : '点击切换到这一卷'),
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onTap(i, vols[i]), onLongPress: () => onLongPress(vols[i])),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 一卷的封面，带状态：读完了打勾，正在读的有"在读"标签，一章都没读的暗一点。
class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.url, required this.width, required this.done, required this.reading, required this.untouched, required this.shade});

  final String url;
  final double width;
  final bool done;
  final bool reading;
  final bool untouched;

  /// 离最前面越远越暗（0~1）
  final double shade;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width / kCoverAspect,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24, offset: const Offset(0, 12))],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.white.withValues(alpha: 0.15)),
          RepaintBoundary(child: NetImage(url, decodeSize: Size(width, width / kCoverAspect), error: const Icon(Icons.menu_book_outlined, color: Colors.white54))),
          ColoredBox(color: Colors.black.withValues(alpha: (shade + (untouched ? 0.2 : 0)).clamp(0, 0.75))),
          if (reading)
            Positioned(
              top: 10,
              left: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
                ),
                child: Text(
                  '在读',
                  style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (done)
            const Positioned(
              right: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Icon(Icons.check_circle, color: Color(0xFF2E9E5B), size: 26),
              ),
            ),
        ],
      ),
    ),
  );
}

String _progress(String aid, Vol v) {
  final read = ReadState.readView(aid);
  final at = Volumes.done(aid)[v.title];
  final d = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  return ['已读 ${v.textCids.where(read.contains).length} / ${v.textCids.length} 章', if (d != null) '${d.year}.${d.month}.${d.day} 读完'].join(' · ');
}

/// 没展开时封面下面的一行：卷名和进度
class _Summary extends StatelessWidget {
  const _Summary({required this.aid, required this.vol, required this.index, required this.count});

  final String aid;
  final Vol vol;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // 固定两行的高度（随系统字号伸缩）：卷名一行还是两行，下面的字都不动
          SizedBox(
            height: 50 * textScale,
            child: Center(
              child: Text(
                vol.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, height: 1.25),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '第 ${index + 1} / $count 卷 · ${_progress(aid, vol)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// 展开后的这一卷：进度、评分、继续读、换封面、阅读报告，以及这一卷的目录。
class _Details extends StatefulWidget {
  const _Details({
    super.key,
    required this.aid,
    required this.vol,
    required this.index,
    required this.chapterTitles,
    required this.book,
    required this.onCache,
    required this.bg,
    required this.onClose,
    this.wide = false,
  });

  final String aid;
  final Vol vol;
  final int index;
  final Map<String, String> chapterTitles;
  final String book;
  final void Function(List<String> cids) onCache;

  /// 页面最终的底色（封面取色）。不能用 Scaffold 当前的颜色：换卷时它正在渐变，取到的是上一卷的颜色
  final Color bg;

  /// 目录在最顶上还往下拉：收起，回到大封面
  final VoidCallback onClose;
  final bool wide;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  final _picked = <String>{}; // 长按多选的章节

  void _pick(String cid) => setState(() => _picked.contains(cid) ? _picked.remove(cid) : _picked.add(cid));

  /// 只选了一章时：整本书里它前面的章节全标为已读（跨卷）
  Future<void> _markBefore() async {
    final all = [for (final v in Volumes.of(widget.aid)) ...v.cids];
    final i = all.indexWhere(_picked.contains);
    if (i > 0) await ReadState.setRead(widget.aid, all.take(i), true);
    if (mounted) setState(_picked.clear);
  }

  Future<void> _mark(bool read) async {
    await ReadState.setRead(widget.aid, _picked, read); // 这卷读没读完会跟着重新核对
    if (mounted) setState(_picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final aid = widget.aid;
    final v = widget.vol;
    final read = ReadState.readView(aid);
    final p = ReadingProgress.of(aid);
    final inVol = p != null && v.cids.contains(p.cid);
    final next = startCid(aid, v);
    final label = inVol ? '继续读' : (v.textCids.every(read.contains) ? '重读这一卷' : '开始读');
    final rating = Volumes.rating(aid, v.title);
    final markedCids = Bookmarks.bookmarkedCids(aid);
    const muted = TextStyle(color: Colors.white60);

    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(child: Text(_progress(aid, v), style: muted.copyWith(fontSize: 12))),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= 5; i++)
                  Semantics(
                    button: true,
                    selected: i <= rating,
                    label: hz(context, '$i 星评分'),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          await Volumes.setRating(aid, v.title, rating == i ? 0 : i); // 再点一次当前星数就取消
                          if (mounted) setState(() {});
                        },
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Center(
                            child: Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFFFFC53D), size: 22),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40), textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                onPressed: () => context.push(Routes.reader(aid, next)).then((_) {
                  if (mounted) setState(() {});
                }),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(label),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: hz(context, '简介与书评'),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: () => context.push(Routes.novel(aid)).then((_) {
                if (mounted) setState(() {});
              }),
              icon: const Icon(Icons.info_outline, size: 20),
            ),
            const SizedBox(width: 6),
            IconButton.outlined(
              tooltip: hz(context, '换封面'),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: () => pickVolumeCover(context, aid, v),
              icon: const Icon(Icons.image_outlined, size: 20),
            ),
            const SizedBox(width: 6),
            IconButton.outlined(
              tooltip: hz(context, '阅读报告'),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: () => context.push(Routes.report(aid, vol: widget.index)),
              icon: const Icon(Icons.insights, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final (i, cid) in v.cids.indexed)
          ChapterSwipe(
            aid: aid,
            book: widget.book,
            cid: cid,
            title: widget.chapterTitles[cid] ?? '第 ${i + 1} 章',
            enabled: _picked.isEmpty,
            backdrop: Color.alphaBlend(Colors.black.withValues(alpha: 0.18), widget.bg),
            onChanged: () => setState(() {}),
            onCache: () => widget.onCache([cid]),
            child: GestureDetector(
              onSecondaryTap: () => _pick(cid),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                // 默认给前面的图标留 40 宽再空 16，章节名左边空一大块
                minLeadingWidth: 20,
                horizontalTitleGap: 8,
                leading: _picked.isNotEmpty
                    ? Icon(_picked.contains(cid) ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: Colors.white70)
                    : (read.contains(cid) ? const Icon(Icons.check, size: 16, color: Colors.white38) : const SizedBox(width: 16)),
                title: Text(
                  widget.chapterTitles[cid] ?? '第 ${i + 1} 章',
                  style: TextStyle(
                    color: cid == p?.cid ? Colors.white : (read.contains(cid) ? Colors.white38 : Colors.white70),
                    fontWeight: cid == p?.cid ? FontWeight.w700 : null,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (markedCids.contains(cid)) ...[
                      const Icon(Icons.bookmark_rounded, size: 15, color: Color(0xFFFFC53D)),
                      const SizedBox(width: 4),
                    ],
                    if (cid == p?.cid)
                      const Text('读到这里', style: TextStyle(color: Colors.white, fontSize: 12))
                    else if (ChapterCache.has(aid, cid))
                      const Icon(Icons.download_for_offline_outlined, size: 15, color: Colors.white38),
                  ],
                ),
                onTap: _picked.isNotEmpty
                    ? () => _pick(cid)
                    : () => context.push(Routes.reader(aid, cid)).then((_) {
                        if (mounted) setState(() {});
                      }),
                onLongPress: () => _pick(cid),
              ),
            ),
          ),
      ],
    );

    return Padding(
      padding: widget.wide ? const EdgeInsets.fromLTRB(4, 4, 16, 16) : const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: widget.wide ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              // 横屏里详情在右侧并排展示，往下拉目录顶头时不应该把右侧面板关掉
              child: widget.wide ? list : PullToClose(onClose: widget.onClose, child: list),
            ),
            if (_picked.isNotEmpty)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.25),
                child: SafeArea(
                  top: false,
                  child: TextButtonTheme(
                    data: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Colors.white)),
                    child: Row(
                      children: [
                        IconButton(tooltip: hz(context, '取消'), color: Colors.white, icon: const Icon(Icons.close), onPressed: () => setState(_picked.clear)),
                        Expanded(
                          child: Text('已选 ${_picked.length} 章', style: const TextStyle(color: Colors.white)),
                        ),
                        TextButton(onPressed: () => _mark(true), child: const Text('已读')),
                        TextButton(onPressed: () => _mark(false), child: const Text('未读')),
                        TextButton(
                          onPressed: () {
                            widget.onCache(_picked.toList());
                            setState(_picked.clear);
                          },
                          child: const Text('缓存'),
                        ),
                        // 按钮全摆出来窄屏放不下，不常用的收进"更多"
                        PopupMenuButton<void Function()>(
                          tooltip: hz(context, '更多'),
                          iconColor: Colors.white,
                          onSelected: (f) => f(),
                          itemBuilder: (_) => [
                            // 从这一卷第一章选到已选的最后一章
                            PopupMenuItem(value: () => setState(() => _picked.addAll(v.cids.take(v.cids.lastIndexWhere(_picked.contains) + 1))), child: const Text('选到开头')),
                            if (_picked.length == 1) PopupMenuItem(value: _markBefore, child: const Text('前面的标为已读')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 封面下面的两个横条：展开 / 收起这一卷的详情和目录，或者全部卷的列表
class _DetailsToggle extends StatelessWidget {
  const _DetailsToggle({required this.open, required this.list, required this.onTap, required this.onList, this.wide = false});

  final bool open;
  final bool list;
  final VoidCallback onTap;
  final VoidCallback onList;
  final bool wide;

  Widget _pill(bool expanded, String text, VoidCallback onTap) => Material(
    color: Colors.white.withValues(alpha: 0.12),
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              wide
                  ? (expanded ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right)
                  : (expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [_pill(open, open ? '收起' : '详情和目录', onTap), _pill(list, list ? '收起' : '全部卷', onList)],
    ),
  );
}

/// 全部卷：三列封面网格（像 Apple Books 的系列页）。读完的打勾，在读的封面底下一条进度，当前这卷描边；点一卷，轮播翻到那一卷。
class _VolList extends StatelessWidget {
  const _VolList({required this.aid, required this.vols, required this.cur, required this.coverOf, required this.onPick, required this.onClose, this.wide = false});

  final String aid;
  final List<Vol> vols;
  final int cur;
  final String Function(Vol) coverOf;
  final ValueChanged<int> onPick;
  final VoidCallback onClose;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final done = Volumes.done(aid);
    final reading = readingVolume(aid);
    final read = ReadState.readView(aid);
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return Padding(
      padding: wide ? const EdgeInsets.fromLTRB(4, 4, 16, 16) : const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: wide ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, c) {
            final n = (c.maxWidth / 120).floor().clamp(3, 6);
            final w = (c.maxWidth - 32 - 12 * (n - 1)) / n;
            final grid = GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              // 一格 = 封面 + 两行卷名（随系统字号伸缩防溢出）
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: n, mainAxisSpacing: 14, crossAxisSpacing: 12, mainAxisExtent: w / kCoverAspect + 6 + 34 * textScale),
              itemCount: vols.length,
              itemBuilder: (context, i) {
                final v = vols[i];
                final finished = done.containsKey(v.title);
                final total = v.textCids.length;
                final progress = i == reading && !finished && total > 0 ? v.textCids.where(read.contains).length / total : null;
                return GestureDetector(
                  onTap: () => onPick(i),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: kCoverAspect,
                        child: DecoratedBox(
                          position: DecorationPosition.foreground,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: i == cur ? Border.all(color: Colors.white, width: 2) : null,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: Colors.white10, child: NetImage(coverOf(v), thumbnail: true, decodeSize: Size(w, w / kCoverAspect))),
                                if (finished)
                                  const Positioned(
                                    top: 5,
                                    right: 5,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                      child: Padding(padding: EdgeInsets.all(2), child: Icon(Icons.check, size: 14, color: Colors.white)),
                                    ),
                                  ),
                                if (progress != null)
                                  Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: progress, minHeight: 4, color: Colors.white, backgroundColor: Colors.black45)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.3, color: i == cur ? Colors.white : Colors.white70, fontWeight: i == cur ? FontWeight.w700 : null),
                      ),
                    ],
                  ),
                );
              },
            );
            return wide ? grid : PullToClose(onClose: onClose, child: grid);
          },
        ),
      ),
    );
  }
}

/// 列表滚到最顶上以后继续往下拉超过一段距离：松手前就触发 [onClose]（每次拖动只触发一次）。
class PullToClose extends StatefulWidget {
  const PullToClose({super.key, required this.onClose, required this.child});

  final VoidCallback onClose;
  final Widget child;

  @override
  State<PullToClose> createState() => _PullToCloseState();
}

class _PullToCloseState extends State<PullToClose> {
  double _pull = 0;
  bool _fired = false;

  bool _on(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification) {
      _pull = 0;
      _fired = false;
    } else if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _pull -= n.overscroll;
    } else if (n is ScrollUpdateNotification && n.dragDetails != null && n.metrics.pixels < 0) {
      _pull = -n.metrics.pixels; // iOS 回弹式滚动
    }
    if (_pull > 70 && !_fired) {
      _fired = true;
      widget.onClose();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(onNotification: _on, child: widget.child);
}

/// 翻开书的动画：封面以左边书脊为轴往外翻开，同时连书页一起放大铺满屏幕；铺满时（[onOpened]）推出阅读页，
/// 再稍等阅读页就位后淡出（[onDone] 里移除自己）。自带计时器，不跟着下面的页面暂停。
class _OpeningBook extends StatefulWidget {
  const _OpeningBook({required this.from, required this.url, required this.pageColor, required this.onOpened, required this.onDone});

  final Rect from;
  final String url;
  final Color pageColor;
  final VoidCallback onOpened;
  final VoidCallback onDone;

  @override
  State<_OpeningBook> createState() => _OpeningBookState();
}

class _OpeningBookState extends State<_OpeningBook> with SingleTickerProviderStateMixin {
  // 0 ~ 0.46 (~300ms) 翻开、放大；0.46 推出阅读页；0.72 ~ 1 淡出
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  bool _pushed = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (!_pushed && _c.value >= 0.46) {
        _pushed = true;
        widget.onOpened();
      }
    });
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final wide = screen.width > screen.height;
    final aspect = widget.from.height > 0 ? widget.from.width / widget.from.height : kCoverAspect;
    final page = widget.pageColor;
    final darkPage = page.computeLuminance() < 0.25;
    final spineMid = darkPage ? Color.lerp(page, Colors.white, 0.04)! : Color.lerp(page, Colors.black, 0.06)!;
    final spineDeep = darkPage ? Colors.black : Color.lerp(page, Colors.black, 0.12)!;
    // 宽屏下封面保持自身竖版比例，避免被拉伸到宽窗口而把上下截断；高度留一点余量防止 3D 旋转透视边越出窗口
    final coverTarget = wide
        ? Rect.fromCenter(
            center: screen.center,
            width: screen.height * 0.84 * aspect,
            height: screen.height * 0.84,
          )
        : screen;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final grow = Curves.easeInOutCubic.transform((_c.value / 0.46).clamp(0.0, 1.0));
          final spread = Curves.easeInCubic.transform((_c.value / 0.46).clamp(0.0, 1.0));
          final turn = Curves.easeInCubic.transform((_c.value / 0.42).clamp(0.0, 1.0)); // 0 合着 → 1 翻到垂直看不见
          final fade = 1 - Curves.easeOut.transform(((_c.value - 0.72) / 0.28).clamp(0.0, 1.0));
          final coverRect = Rect.lerp(widget.from, coverTarget, grow)!;
          final pageRect = wide ? Rect.lerp(coverRect, screen, spread)! : coverRect;
          final radius = BorderRadius.circular(8 * (1 - grow));
          final persp = (0.25 / math.max(coverRect.width, 1.0)).clamp(0.0002, 0.0009);
          return Opacity(
            opacity: fade,
            child: Stack(
              children: [
                // 书页：跟随阅读器背景色（夜间/纯黑不闪白），书脊那边有一点阴影
                Positioned.fromRect(
                  rect: pageRect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: wide
                          ? LinearGradient(
                              colors: [page, spineMid, spineDeep, page, page],
                              stops: const [0.0, 0.48, 0.5, 0.53, 1.0],
                            )
                          : LinearGradient(colors: [spineDeep, page, page], stops: const [0, 0.08, 1]),
                    ),
                  ),
                ),
                if (turn < 1)
                  Positioned.fromRect(
                    rect: coverRect,
                    child: Transform(
                      alignment: Alignment.centerLeft,
                      // 右边朝人抬起来往左翻（真书翻开封面的方向）；透视随封面宽度自适应，避免宽屏下右边转近时放大溢出屏幕上下边界
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, persp)
                        ..rotateY(turn * math.pi / 2),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FittedBox(
                              fit: BoxFit.fill,
                              child: SizedBox.fromSize(
                                size: widget.from.size,
                                child: NetImage(widget.url),
                              ),
                            ),
                            // 翻得越开越暗，像封面背光
                            ColoredBox(color: Colors.black.withValues(alpha: 0.45 * turn)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
