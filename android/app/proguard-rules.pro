# Ark Novel Android R8 / ProGuard 规则

# 应用原生入口（MainActivity / ReadingWidget / Upscaler）
-keep class io.github.chenshi221.ark_novel.** { *; }

# LiteRT (TensorFlow Lite) JNI 回调与反射类
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# Cronet（无 Play 服务内嵌版）反射与 JNI
-keep class org.chromium.net.** { *; }
-dontwarn org.chromium.net.**
-dontwarn com.google.android.gms.**

# audio_service / MediaBrowserService / MediaButtonReceiver
-keep class com.ryanheise.audioservice.** { *; }
-keep class androidx.media.** { *; }
-dontwarn com.ryanheise.audioservice.**

# home_widget 桌面小组件 Provider
-keep class es.antonborri.home_widget.** { *; }

# flutter_inappwebview WebView JS 桥与回调
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-dontwarn com.pichillilorenzo.flutter_inappwebview_android.**

# 常见可选反射依赖消除误报警告
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
