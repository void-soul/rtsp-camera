# RTSP Camera

A cross-platform native RTSP camera streaming app that turns your phone into a high-performance RTSP server. Supports up to **4K/60FPS** with hardware-accelerated **H.264/H.265** encoding and real-time camera controls.

- **Android** — Kotlin, `com.gld.rtsp_camera`
- **iOS** — Swift, `RTSPCamera` (v1.0.1)

## Highlights

- **Fully native** — No cross-platform frameworks. Kotlin on Android, Swift on iOS. Zero GC pressure, minimal CPU overhead.
- **Zero-copy pipeline** — `Camera → Surface → Hardware Encoder` on Android; `AVCaptureSession → CVPixelBuffer → VideoToolbox` on iOS. Pixel data stays in dedicated hardware buffers.
- **H.264 & H.265** — Both codecs supported on both platforms with hardware acceleration.
- **TCP & UDP** — Automatic mode selection via RTSP `Transport` negotiation. TCP interleaved with per-packet micro-pacing for smooth delivery.
- **Adaptive Bitrate** — RTCP-based congestion detection drops bitrate to 75% on >5% packet loss, recovers by 10% after 30s of zero loss.
- **Real-time performance HUD** — FPS, ABR, CPU, memory, network throughput, battery, frame counters, and packet loss all visible during streaming.

## Core Features

### Camera Controls

| Feature | Android | iOS |
|---------|---------|-----|
| Resolution | 4K / 1080p / 720p | 4K / 1080p / 720p |
| Frame rate | Up to device max (120) | Up to device max |
| Manual zoom | 1x–10x slider | 1x–10x slider |
| Exposure bias | −3 to +3 EV | −3 to +3 EV |
| Manual focus | Focus distance slider + AF toggle | Lens position slider + AF toggle |
| Torch / Flash | Toggle during streaming | Toggle during streaming |
| Camera flip | Front/rear switch | Front/rear switch |
| White balance | AUTO, Incandescent, Fluorescent, Daylight, Cloudy | Auto (via AVCaptureDevice) |
| Color filters | MONO, NEGATIVE, SOLARIZE, SEPIA, POSTERIZE | Planned (tracked, not applied) |
| Edge enhancement | Hardware sharpness control | N/A |
| Distortion correction | Camera2 hardware mode | N/A |
| Stabilization | OIS + EIS (independent toggles) | Auto OIS/EIS (combined) |

### Streaming Configuration

- **GOP control** — Adjustable keyframe interval (1–120 frames)
- **Dynamic bitrate** — 5–60 Mbps, adjustable mid-stream without restart
- **Codec selection** — H.264 or H.265, configurable before starting
- **Audio** — AAC-LC 44.1 kHz (optional, disable before starting)
- **Network** — Configurable RTSP port and path
- **Language** — English / Chinese / Auto (runtime switching, no restart)

### RTSP Server

- Full RTSP 1.0 state machine: `OPTIONS → DESCRIBE → SETUP → PLAY → TEARDOWN`
- SDP generation with extracted SPS/PPS/VPS parameter sets
- Single-client mode (453 Not Enough Bandwidth for additional clients)
- Client IP display and disconnect alert with flashing red border
- TCP interleaved mode (`$|ch|len`) and UDP unicast mode

## Architecture

```
Camera API  →  Hardware Encoder  →  Frame Provider  →  RTP Sender  →  UDP/TCP
   ↑                ↑                    ↑                  ↑
   |          SettingsManager       Frame Pool        RTCP Sender (SR/RR)
   |                                     |
Settings UI                        Low-latency Queue (capacity 5)
```

### Layer Responsibilities

**Android** — `Camera2 → Surface → MediaCodec → H264FrameProvider → RTPSender → Client`

**iOS** — `AVCaptureSession → CVPixelBuffer → VTCompressionSession → VideoFrameProvider → RTPSender → Client`

### Key Design Patterns

- **Frame pool** — Pre-allocated buffer pools avoid GC/ARC pressure during streaming (10 × 2MB video buffers, reusable NALU arrays)
- **Low-latency queue** — Frame provider uses capacity-5 blocking queue (~167 ms at 30 FPS); overflow triggers keyframe request
- **FPS auto-detection** — Automatically detects actual camera FPS; restarts encoder if below target to fix SPS VUI timing
- **Dynamic parameters** — Bitrate, FPS, GOP adjustable during active stream without restart
- **Frame-level backpressure** — `DispatchSemaphore(value: 4)` on iOS; `BlockingQueue` + synchronous socket writes on Android
- **TCP micro-pacing** — Per-packet 80 µs spacing to prevent burst delivery over NWConnection (iOS)

## Getting Started

### Android

**Requirements:** Android Studio, JDK 17, Android 8.0+ (API 24) device

```bash
cd android
./gradlew.bat assembleDebug          # Build debug APK
./gradlew.bat :app:assembleRelease   # Build release APK (ProGuard + shrink)
```

Build output: `android/app/build/outputs/apk/`

### iOS

**Requirements:** Xcode 15+, iOS 13+ device

```bash
xcodebuild -project ios/RTSPCamera.xcodeproj \
  -scheme RTSPCamera \
  -sdk iphonesimulator \
  -configuration Debug build
```

### Testing the Stream

1. Connect your phone and player (VLC, PotPlayer, ffplay) to the same local network
2. Tap the start button — the RTSP URL appears in the top bar
3. Open the URL in your player: `rtsp://<phone-ip>:8554/live`

## Build Configuration

| | Android | iOS |
|---|---------|-----|
| Language | Kotlin 2.0.21 | Swift 5 |
| Build system | Gradle 8.13 (Groovy DSL) | Xcode project |
| AGP | 8.13.2 | — |
| Min SDK / Target | API 24 / 35 | iOS 13 |
| Compile SDK | 36 | — |
| JVM target | 17 | — |
| ABI filters | armeabi-v7a, arm64-v8a | arm64 |
| ProGuard | Enabled (release) | N/A |
| Page alignment | 16 KB (Android 15+) | N/A |

## Testing

### Android (JUnit 4)

```bash
cd android
./gradlew.bat :app:testDebugUnitTest
```

Test files:
- `RTPSenderTest.kt` — NAL unit parsing, FU-A fragmentation, RTP packetization
- `H264EncoderTest.kt` — Color conversion (YUV ↔ NV12)
- `SettingsManagerTest.kt` — SharedPreferences migration logic
- `H264FrameProviderTest.kt` — Frame pool allocation and SPS/PPS handling
- `AudioFrameProviderTest.kt` — Audio buffer pool

### iOS

No unit tests configured yet.

## CI/CD

GitHub Actions (`.github/workflows/build.yml`):
- Triggers on push to `main`/`master`, pull requests, and manual dispatch
- **Android**: Builds release APK on `ubuntu-latest`
- **iOS**: Builds unsigned IPA on `macos-14` with Xcode 15.4
- **Release**: Creates GitHub release with APK and IPA artifacts on push to main

## Platform Differences

| Aspect | Android | iOS |
|--------|---------|-----|
| Camera API | CameraX + Camera2 interop | AVCaptureSession |
| Encoder | MediaCodec (Surface input) | VideoToolbox (CVPixelBuffer input) |
| Encoder input | Zero-copy Surface | CVPixelBuffer from AVCaptureVideoDataOutput |
| UDP socket | `java.net.DatagramSocket` | `Network.framework NWConnection` |
| TCP pacing | Batch buffer per frame | Per-packet 80 µs micro-pacing |
| Backpressure | Implicit (synchronous write) | Explicit (semaphore-based frame throttling) |
| Background streaming | Foreground service + WakeLock | Audio background mode |
| Color filters | Hardware `CONTROL_EFFECT_MODE` | Not available (tracked in UI) |
| Stabilization | OIS + EIS independent toggles | Combined `.auto` mode |
| UI framework | XML layouts + programmatic | SwiftUI |

## License

This project is for learning and research purposes.
