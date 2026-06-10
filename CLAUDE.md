# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Native Android RTSP camera streaming app (Kotlin). Converts an Android phone into an RTSP server supporting up to 4K/60FPS with hardware-accelerated H.264 encoding. Package: `com.gld.rtsp_camera`.

## Build Commands

All commands run from the `android/` directory using `gradlew.bat`:

```bash
gradlew.bat assembleDebug              # Build debug APK
gradlew.bat :app:assembleDebug         # Same, explicit module
gradlew.bat :app:compileDebugKotlin    # Compile Kotlin only
gradlew.bat :app:testDebugUnitTest     # Run all unit tests
gradlew.bat :app:testDebugUnitTest --tests "com.gld.rtsp_camera.RTPSenderTest"  # Single test class
```

## Architecture

Data pipeline: `Camera2 → Surface → MediaCodec (H264Encoder) → H264FrameProvider → RTPSender → UDP/TCP → RTSP Client`

### Layer Responsibilities

- **Activity/UI**: `MainActivity` (lifecycle, permissions), `UiController` (popups, ruler wheel, status), `MainEventHandlers` (callback wiring), `RulerWheelView` (custom scroll wheel)
- **Camera**: `CameraManager` (CameraX binding, YUV→NV12, center-crop, FPS detection, Camera2 interop), `CameraCapabilities` (hardware feature data class)
- **Encoding**: `H264Encoder` (MediaCodec H.264, Surface/Buffer input, dynamic bitrate), `AudioEncoder` (AAC-LC at 44.1kHz), `H264FrameProvider` / `AudioFrameProvider` (zero-allocation frame pools with blocking queues)
- **Streaming**: `StreamManager` (pipeline orchestration, WakeLock, session lifecycle), `SimpleRTSPServer` (RTSP protocol, SDP generation, single-client), `RTPSender` / `AudioRTPSender` / `RTCPSender` (RTP packetization, FU-A fragmentation, RTCP SR)
- **Config**: `SettingsManager` (SharedPreferences singleton, value migration), `Utils` (IP detection, locale wrapping)

### Key Design Patterns

- **Frame pool**: Pre-allocated buffer pools (10 × 2MB video, 50 × 4KB audio) avoid GC pressure during streaming
- **Low-latency queue**: H264FrameProvider uses capacity-5 queue (~167ms at 30fps); overflow triggers keyframe request
- **FPS auto-adjustment**: Detects actual camera FPS, restarts encoder if below target to fix SPS VUI timing
- **Dynamic parameters**: Bitrate, FPS, GOP adjustable during active stream without restart
- **Single client**: RTSP server rejects additional clients with "453 Not Enough Bandwidth"

## Build Configuration

- Build files use Groovy DSL (`.gradle`), not Kotlin DSL (`.gradle.kts`)
- Gradle 8.13, AGP 8.13.2, Kotlin 2.0.21
- Compile SDK 36, Min SDK 24, Target SDK 35, JVM target 17
- ABI filters: `armeabi-v7a`, `arm64-v8a`
- ProGuard enabled for release (`minifyEnabled`, `shrinkResources`)
- `unitTests.returnDefaultValues = true` for JVM tests
- CameraX extensions intentionally excluded (contains unaligned `libimage_processing_util_jni.so`)
- 16KB page alignment enabled via `jniLibs.useLegacyPackaging = true` (Android 15+ compatibility)

## Testing

JUnit 4 unit tests in `android/app/src/test/kotlin/com/gld/rtsp_camera/`. Tests replicate private algorithms as static helpers for testability. Key test files: `RTPSenderTest` (NAL/FU-A), `H264EncoderTest` (color conversion), `SettingsManagerTest` (migration logic), `H264FrameProviderTest` (pool/SPS), `AudioFrameProviderTest` (pool).

## i18n

English (`values/strings.xml`) and Chinese (`values-zh/strings.xml`). Language switching uses `Utils.wrapContext()` for runtime locale override.
