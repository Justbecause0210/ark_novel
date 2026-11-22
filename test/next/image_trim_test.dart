import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/session.dart';

/// 构造带合法 JPEG 魔数的短字节，用于单测区分不同响应。
List<int> _jpeg(int tag) => [0xFF, 0xD8, 0xFF, 0xE0, tag];

/// 假网络：记下请求的地址，默认返回合法 JPEG 字节，也可按请求定制响应或抛错
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter([this._onFetch]);

  final Future<ResponseBody> Function(RequestOptions options)? _onFetch;
  final urls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    urls.add(options.uri.toString());
    if (_onFetch != null) return _onFetch(options);
    return ResponseBody.fromBytes(_jpeg(1), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('trimDir 超限时删最旧的，未超限不动', () async {
    final dir = await Directory.systemTemp.createTemp('trim');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      final f = File('${dir.path}/f$i')..writeAsBytesSync(List.filled(100, 0));
      f.setLastModifiedSync(now.subtract(Duration(minutes: 5 - i))); // f0 最旧
    }
    await trimDir(dir, 500);
    expect(dir.listSync().length, 5);

    await trimDir(dir, 400); // 总 500 > 400：删到 ≤320，即只留最新的 3 个
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {'f2', 'f3', 'f4'});
  });

  test('load 下载完能返回（不会自己等自己卡死），封面图床走 http，第二次从缓存拿', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter();
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://img.wenku8.com/image/1/1158/1158s.jpg';
    expect(await store.load(url).timeout(const Duration(seconds: 2)), _jpeg(1));
    expect(net.urls, ['http://img.wenku8.com/image/1/1158/1158s.jpg']);
    expect(await store.load(url).timeout(const Duration(seconds: 2)), _jpeg(1));
    expect(net.urls, hasLength(1));
  });

  test('pic.777743.xyz 下载失败时自动回退到 pic.wenku8.com，并按原地址缓存', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_fallback');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') throw DioException.connectionError(requestOptions: o, reason: 'blocked');
      return ResponseBody.fromBytes(_jpeg(7), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://pic.777743.xyz/pictures/1/1973/100/1.jpg';
    expect(await store.load(url), _jpeg(7));
    expect(net.urls, ['https://pic.777743.xyz/pictures/1/1973/100/1.jpg', 'https://pic.wenku8.com/pictures/1/1973/100/1.jpg']);
    // 第二次直接命中缓存，不再请求网络
    expect(await store.load(url), _jpeg(7));
    expect(net.urls, hasLength(2));
  });

  test('pic.777743.xyz 返回 HTML 拦截页时也回退到 pic.wenku8.com；无备用地址的失败不重复请求', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_html');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') return ResponseBody.fromString('<html>blocked</html>', 200);
      if (o.uri.path.contains('fail')) return ResponseBody.fromBytes([], 404);
      return ResponseBody.fromBytes(_jpeg(4), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/1.jpg'), _jpeg(4));
    expect(net.urls, ['https://pic.777743.xyz/pictures/1/1/1.jpg', 'https://pic.wenku8.com/pictures/1/1/1.jpg']);

    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/fail.jpg'), throwsA(isA<Object>()));
    expect(net.urls, hasLength(3));
  });

  test('图床 403 时同域名并发只拉起一次网页过盾，放行后其余图继续走 Dio 下载', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cf_dedup');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    var cleared = false;
    final challengeCalls = <String>[];
    final net = _FakeAdapter((o) async {
      if (!cleared) return ResponseBody.fromBytes(const [], 403);
      return ResponseBody.fromBytes(_jpeg(o.uri.path.endsWith('1.jpg') ? 1 : 2), 200);
    });
    final gate = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls.add(url);
          await gate.future;
          cleared = true;
          return Uint8List.fromList(_jpeg(url.endsWith('1.jpg') ? 1 : 2));
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    final f1 = store.load('https://pic.wenku8.com/pictures/1/1/1.jpg');
    final f2 = store.load('https://pic.wenku8.com/pictures/1/1/2.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(challengeCalls, hasLength(1));
    gate.complete();

    expect(await f1, _jpeg(1));
    expect(await f2, _jpeg(2));
    expect(challengeCalls, hasLength(1));
  });

  test('主地址断连且备用域名 403 时，只对备用域名过盾；404 不触发网页过盾', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cf_alt');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final challengeCalls = <String>[];
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') throw DioException.connectionError(requestOptions: o, reason: 'dns fail');
      if (o.uri.path.endsWith('404.jpg')) return ResponseBody.fromBytes(const [], 404);
      return ResponseBody.fromBytes(const [], 403);
    });
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls.add(url);
          return Uint8List.fromList(_jpeg(9));
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/cover.jpg'), _jpeg(9));
    expect(challengeCalls, ['https://pic.wenku8.com/pictures/1/1/cover.jpg']);

    await expectLater(store.load('https://pic.777743.xyz/pictures/1/1/404.jpg'), throwsA(isA<Object>()));
    expect(challengeCalls, hasLength(1));
  });

  test('imageDioProvider 会自动恢复并携带该图床保存的 cf_clearance cookie', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cookie');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final sessionStore = await SessionStore.open();
    await sessionStore.setNativeNet(false);
    await sessionStore.setCfCookie('https://pic.777743.xyz', 'cf_clearance=abc123');

    String? sentCookie;
    final net = _FakeAdapter((o) async {
      sentCookie = o.headers['cookie'] as String?;
      return ResponseBody.fromBytes(_jpeg(5), 200);
    });
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(sessionStore)]);
    addTearDown(c.dispose);
    c.read(imageDioProvider).httpClientAdapter = net;

    expect(await c.read(imageStoreProvider).load('https://pic.777743.xyz/pictures/1/1/1.jpg'), _jpeg(5));
    expect(sentCookie, contains('cf_clearance=abc123'));
  });

  test('非图片魔数响应拒绝落盘并回退备用图床；无备用地址时报错且不污染缓存', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_magic');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') return ResponseBody.fromString('{"error":"rate limited"}', 200);
      if (o.uri.path.contains('bad')) return ResponseBody.fromString('plain error body', 200);
      return ResponseBody.fromBytes(_jpeg(8), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/ok.jpg'), _jpeg(8));
    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/bad.jpg'), throwsA(isA<StateError>()));
    expect(await store.cached('https://pic.wenku8.com/pictures/1/1/bad.jpg'), isNull);
  });

  test('图床 challenge 失败后进入冷却窗口，冷却期内同域名不重复拉起过盾', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cooldown');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    var challengeCalls = 0;
    final net = _FakeAdapter((o) async => ResponseBody.fromBytes(const [], 403));
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls++;
          throw CloudflareChallengeException(requestOptions: RequestOptions(path: url));
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/a.jpg'), throwsA(isA<CloudflareChallengeException>()));
    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/b.jpg'), throwsA(isA<CloudflareChallengeException>()));
    expect(challengeCalls, 1);
  });

  test('cancelPrefetch 取消尚未开始的低优预取，且可见图加载优先于预取队列', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_priority');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final gates = <String, Completer<void>>{};
    final started = <String>[];
    final net = _FakeAdapter((o) async {
      final name = o.uri.pathSegments.last;
      started.add(name);
      final gate = gates[name];
      if (gate != null) await gate.future;
      return ResponseBody.fromBytes(_jpeg(started.length), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    // 先占满 4 个网络槽位，再排 2 个低优预取与 1 个高优可见加载
    for (var i = 1; i <= 4; i++) {
      gates['slot$i.jpg'] = Completer<void>();
    }
    final slotFutures = [for (var i = 1; i <= 4; i++) store.load('https://img.example/slot$i.jpg')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, hasLength(4));

    store.prefetch(['https://img.example/pre1.jpg', 'https://img.example/pre2.jpg']);
    final visibleFuture = store.load('https://img.example/visible.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 取消未开始的预取，仅保留 visible.jpg
    store.cancelPrefetch(['https://img.example/pre1.jpg', 'https://img.example/pre2.jpg']);
    for (final g in gates.values) {
      g.complete();
    }
    await Future.wait([...slotFutures, visibleFuture]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(started, contains('visible.jpg'));
    expect(started, isNot(contains('pre1.jpg')));
    expect(started, isNot(contains('pre2.jpg')));
  });
}
