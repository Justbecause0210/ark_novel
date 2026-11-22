import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/custom_exception.dart';

Future<void> _tail = Future.value();

/// 相邻两次加载至少隔这么久：网页一页带出好几个请求，连着开会被 Cloudflare 限流成 Access denied
const _gap = Duration(seconds: 1);

Future<T> _enqueue<T>(Future<T> Function() run) {
  final result = _tail.then((_) => run());
  _tail = result.then<void>((_) {}, onError: (_) {}).then((_) => Future<void>.delayed(_gap));
  return result;
}

/// 检测到需要用户交互的 Turnstile / 挑战页后，等待这么久仍未自动跳转就快速上抛引导人工验证（不再干等 20s）。
const _interactiveGrace = Duration(seconds: 4);

/// App 自己的请求被 Cloudflare 拦下时，改用不显示的网页加载同一地址并取整页 HTML。
/// 网页是真浏览器，Cloudflare 通常直接放行；cookie 和登录用的网页共用，登录状态自然带上。
/// 一次只开一个网页，其余排队。网页也过不去（一直停在验证页）就照旧抛 [CloudflareChallengeException]，让界面提示去验证。
Future<String> webFetch(String url, {String? referer, String proxy = '', Future<void> Function(String cookies, String? userAgent, String origin)? onSession}) =>
    _enqueue(() => _load(url, referer, proxy, onSession));

/// 图片请求被 Cloudflare 拦下时，用不显示的网页过一次盾并取回图片字节；同时通过 [onSession] 把该图床的 `cf_clearance` 和 UA 带回给 Dio 并发下载。
Future<Uint8List> webFetchImage(String url, {String? referer, String proxy = '', Future<void> Function(String cookies, String? userAgent, String origin)? onSession}) =>
    _enqueue(() => _loadImage(url, referer, proxy, onSession));

/// WebView 的代理是整个进程共用的，跟着设置走：请求页面和网页的出口才一致，清空设置后也不会留着旧代理（只有 Android 支持）。
Future<void> applyWebViewProxy(String proxy) async {
  if (!Platform.isAndroid) return;
  try {
    final controller = ProxyController.instance();
    final clean = proxy.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').trim();
    if (clean.isEmpty) {
      await controller.clearProxyOverride();
    } else {
      await controller.setProxyOverride(settings: ProxySettings(proxyRules: [ProxyRule(url: 'http://$clean')]));
    }
  } catch (_) {}
}

bool _isChallengeTitle(String title) => title.contains('Just a moment') || title.contains('请稍候') || title.contains('Checking your browser');

bool _isBlockedTitle(String title) =>
    title.startsWith('Access denied') || title.contains('Attention Required') || title.contains('已被封锁') || title.contains('have been blocked');

const _challengeDomQuery = "!!document.querySelector('#challenge-form, #challenge-running, .cf-turnstile, #cf-challenge-running')";
const _interactiveDomQuery =
    "!!document.querySelector('iframe[src*=\"challenges.cloudflare.com\"], iframe[src*=\"turnstile\"], .cf-turnstile, input[name=\"cf-turnstile-response\"], #turnstile-wrapper, #challenge-stage input[type=\"checkbox\"]')";

String _originOf(String fallbackUrl, WebUri? loadedUri) {
  final host = (loadedUri?.host.isNotEmpty ?? false) ? loadedUri!.host : Uri.parse(fallbackUrl).host;
  return 'https://$host';
}

Future<bool> _hasInteractiveChallenge(InAppWebViewController c) async {
  try {
    return await c.evaluateJavascript(source: _interactiveDomQuery) == true;
  } catch (_) {
    return false;
  }
}

Future<String> _load(String url, String? referer, String proxy, Future<void> Function(String cookies, String? userAgent, String origin)? onSession) async {
  await applyWebViewProxy(proxy);
  final done = Completer<String>();
  Timer? fastFailTimer;
  Timer? probeTimer;

  void cancelTimers() {
    fastFailTimer?.cancel();
    fastFailTimer = null;
    probeTimer?.cancel();
    probeTimer = null;
  }

  void armInteractiveFastFail(InAppWebViewController c) {
    if (fastFailTimer != null || done.isCompleted) return;
    void failFast(Duration grace) {
      fastFailTimer ??= Timer(grace, () {
        if (!done.isCompleted) done.completeError(CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
      });
    }

    unawaited(() async {
      if (await _hasInteractiveChallenge(c)) {
        failFast(_interactiveGrace);
        return;
      }
      // Turnstile iframe 常在页面加载完成后 1~2 秒异步注入，补检一次
      probeTimer?.cancel();
      probeTimer = Timer(const Duration(milliseconds: 1500), () {
        if (done.isCompleted) return;
        unawaited(() async {
          if (await _hasInteractiveChallenge(c)) {
            failFast(const Duration(seconds: 3));
          }
        }());
      });
    }());
  }

  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    // 只要 HTML，不下图片，少发请求
    initialSettings: InAppWebViewSettings(blockNetworkImage: true),
    onLoadStop: (c, loadedUri) async {
      try {
        final title = await c.getTitle() ?? '';
        if (_isBlockedTitle(title)) {
          cancelTimers();
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        // Cloudflare 的验证页过了会自己跳走；若检测到需交互的 Turnstile 且短时间未自动跳转，尽快上抛引导人工验证
        final hasChallengeDom = _isChallengeTitle(title) || await c.evaluateJavascript(source: _challengeDomQuery) == true;
        if (hasChallengeDom) {
          armInteractiveFastFail(c);
          return;
        }
        cancelTimers();
        final html = await c.evaluateJavascript(source: 'document.documentElement.outerHTML');
        if (done.isCompleted) return;
        if (html is String) {
          if (onSession != null) {
            try {
              final origin = _originOf(url, loadedUri);
              final list = await CookieManager.instance().getCookies(url: WebUri(origin));
              final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
              final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
              if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null, origin);
            } catch (_) {}
          }
          if (!done.isCompleted) done.complete(html);
        } else {
          done.completeError(DioException(requestOptions: RequestOptions(path: url), message: 'empty webview html'));
        }
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 10), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    cancelTimers();
    await view.dispose();
  }
}

Future<Uint8List> _loadImage(String url, String? referer, String proxy, Future<void> Function(String cookies, String? userAgent, String origin)? onSession) async {
  await applyWebViewProxy(proxy);
  final done = Completer<Uint8List>();
  Timer? fastFailTimer;
  Timer? probeTimer;

  void cancelTimers() {
    fastFailTimer?.cancel();
    fastFailTimer = null;
    probeTimer?.cancel();
    probeTimer = null;
  }

  void armInteractiveFastFail(InAppWebViewController c) {
    if (fastFailTimer != null || done.isCompleted) return;
    void failFast(Duration grace) {
      fastFailTimer ??= Timer(grace, () {
        if (!done.isCompleted) done.completeError(CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
      });
    }

    unawaited(() async {
      if (await _hasInteractiveChallenge(c)) {
        failFast(_interactiveGrace);
        return;
      }
      probeTimer?.cancel();
      probeTimer = Timer(const Duration(milliseconds: 1500), () {
        if (done.isCompleted) return;
        unawaited(() async {
          if (await _hasInteractiveChallenge(c)) {
            failFast(const Duration(seconds: 3));
          }
        }());
      });
    }());
  }

  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    onLoadStop: (c, loadedUri) async {
      try {
        final title = await c.getTitle() ?? '';
        if (_isBlockedTitle(title)) {
          cancelTimers();
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        if (_isChallengeTitle(title) || await c.evaluateJavascript(source: _challengeDomQuery) == true) {
          armInteractiveFastFail(c);
          return;
        }
        cancelTimers();
        final origin = _originOf(url, loadedUri);
        final res = await c.callAsyncJavaScript(
          functionBody: '''
            const res = await fetch(location.href, { credentials: 'include' });
            if (!res.ok) return { error: 'http:' + res.status };
            const ct = (res.headers.get('content-type') || '').toLowerCase();
            if (ct.includes('text/html')) return { error: 'html:' + (document.title || '') };
            const buf = await res.arrayBuffer();
            const bytes = new Uint8Array(buf);
            if (bytes.length === 0 || (bytes.length > 5 && bytes[0] === 0x3C)) return { error: 'html-body' };
            let bin = '';
            for (let i = 0; i < bytes.length; i += 0x8000) {
              bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            }
            return { b64: btoa(bin) };
          ''',
        );
        if (done.isCompleted) return;
        if (onSession != null) {
          try {
            final list = await CookieManager.instance().getCookies(url: WebUri(origin));
            final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
            final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
            if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null, origin);
          } catch (_) {}
        }
        final map = res?.value is Map ? Map<String, dynamic>.from(res!.value as Map) : null;
        final b64 = map?['b64'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          done.complete(base64Decode(b64));
        } else {
          final err = map?['error'] ?? res?.error ?? 'empty image response';
          done.completeError(DioException(requestOptions: RequestOptions(path: url), message: '$err'));
        }
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 10), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    cancelTimers();
    await view.dispose();
  }
}
