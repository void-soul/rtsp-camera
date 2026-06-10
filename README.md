# Android 原生高性能 RTSP 摄像头推流应用

基于 Kotlin 开发的高性能 Android RTSP 摄像头应用，旨在将 Android 手机转换为专业级的 RTSP 流媒体服务器。本项目通过原生 **Camera2 API** 和 **MediaCodec 硬件编码**，实现了极低延迟、高稳定性的推流性能，最高支持 **4K/60FPS**（取决于硬件支持）。

## 项目亮点

- **全原生架构**：放弃了 Flutter 采集方案，采用纯 Kotlin 开发，消除了 GC 带来的掉帧和内存压力。
- **Zero-Copy 数据链路**：采用 `Camera2 -> Surface -> MediaCodec` 的零拷贝硬件链路。图像数据直接在 GPU 显存中传输，CPU 负载极低。
- **专业级控制**：提供类似专业相机的对焦、曝光、缩放手动控制，并支持硬件防抖（OIS/EIS）。
- **实时监测**：内置轻量级 RTSP 服务器，支持多客户端同时接入，并能实时在界面显示已连接的客户端地址。

## 核心功能

### 1. 相机控制
- **手动/自动对焦**：支持手动滑块对焦及一键切换回自动对焦（AF）。
- **曝光调节**：支持实时曝光补偿（亮度）调节。
- **缩放系统**：支持平滑缩放及 1x、广角快切按钮。
- **闪光灯/手电筒**：推流过程中可实时开启/关闭物理补光灯。
- **场景与滤镜**：支持硬件级场景模式（运动、夜景、人像等）和硬件滤镜（黑白、复古、反色等），通过底部菜单快速切换。

### 2. 推流配置
- **分辨率控制**：支持 4K、2K、1080p、720p 等多档分辨率。
- **码率设置**：支持以 Mbps 为单位的动态码率设置（建议 10-60 Mbps）。
- **帧率 (FPS)**：最高支持 60/120 FPS（取决于设备物理上限）。
- **GOP 调节**：可自定义 I 帧间隔。

### 3. RTSP 服务
- **标准协议**：支持完整的 RTSP 状态机（OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN）。
- **客户端跟踪**：实时在界面展示当前所有连接的客户端 IP 地址。
- **前台服务**：采用 Android 前台服务，确保推流在后台或锁屏状态下依然稳定运行。

### 4. 界面与交互
- **沉浸式预览**：全屏相机预览，控件分布在屏幕四周，中心区域开阔。
- **UI 隐藏模式**：一键切换“纯净视图”，隐藏所有滑动条和按钮，仅保留推流开关。
- **侧边控制**：对焦与亮度滑块采用横向并排布局，避免遮挡信息区。

## 系统架构

```mermaid
graph TD
    A[Camera2 API] -->|Surface| B[MediaCodec Hardware Encoder]
    B -->|H.264 NALUs| C[H264FrameProvider]
    C -->|RTP Packetization| D[RTPSender]
    D -->|UDP| E[RTSP Client (VLC/PotPlayer)]
    F[SimpleRTSPServer] -->|SDP/Setup| E
    G[SettingsManager] -->|Config| A
    G -->|Config| B
```

## 技术实现细节

- **图像采集**：使用 `CameraCharacteristics` 动态探测硬件极限参数（FPS 范围、ISO 范围等）。
- **防抖控制**：在设置中可开启 **OIS（光学防抖）**、**EIS（电子防抖）** 及 **畸变矫正**。
- **边缘增强**：支持硬件级锐度调节（Edge Enhancement）。
- **编码器**：优先调用厂商优化后的硬件编码器（如 `c2.qti.avc.encoder`）。

## 如何开始

1. **环境要求**：
   - Android Studio Jellyfish 或更高版本。
   - Android 9.0 (API 28) 或更高版本设备（推荐高通骁龙 8 系列）。
2. **安装运行**：
   - 克隆仓库，在 Android Studio 中打开 `android` 目录。
   - 编译并安装到真机。
3. **连接测试**：
   - 确保手机与播放端在同一局域网。
   - 开启推流，在 VLC 或 PotPlayer 中输入界面显示的 RTSP 地址。

## 许可证

本项目仅供学习与研究使用。
