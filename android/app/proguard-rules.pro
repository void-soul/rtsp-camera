# RTSP Camera ProGuard Rules

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep CameraX classes
-keep class androidx.camera.** { *; }

# Keep SharedPreferences keys used by SettingsManager
-keepclassmembers class com.gld.rtsp_camera.SettingsManager {
    <fields>;
}

# Keep RulerWheelView (custom view referenced from XML)
-keep class com.gld.rtsp_camera.RulerWheelView { *; }

# Suppress warnings for missing annotations
-dontwarn javax.annotation.**
-dontwarn sun.misc.Unsafe
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**

# Guava
-dontwarn com.google.common.**
-dontwarn com.google.j2objc.annotations.**
