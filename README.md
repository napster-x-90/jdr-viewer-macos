# JDR Viewer for macOS · 블랙박스 뷰어

스미스클럽 VNB350 블랙박스의 JDR 녹화 파일을 맥에서 재생하고 MP4로 저장하는 앱입니다. macOS 14 이상에서 실행되며 영상 처리는 맥에서 이루어집니다.

- USB나 `data` 폴더, 또는 개별 JDR 파일을 열 수 있습니다.
- 날짜별로 녹화 구간을 찾고, 채널 00과 01을 동시에 재생하거나 하나만 볼 수 있습니다.
- 녹화 구간을 선택한 뒤 **MP4 저장**에서 채널을 고르면 해당 구간 전체가 저장됩니다. 지원되는 녹음은 MP4에 포함됩니다.
- 녹화 파일은 읽기 전용으로 열며, MP4는 사용자가 지정한 위치에 별도로 저장합니다.

## 빌드

macOS에서 Xcode 또는 Xcode Command Line Tools를 준비한 뒤 저장소 디렉터리에서 실행합니다.

```sh
./build.sh
open "build/블랙박스 뷰어.app"
```

빌드 결과는 현재 맥의 아키텍처를 사용합니다. 앱 번들에는 로컬 실행용 서명이 적용됩니다.

## 지원 범위

스미스클럽 VNB350의 `1NAJ / 1VEJ / 1BEJ` 구조와 H.264 녹화를 실제 USB에서 확인했습니다. 다른 모델의 JDR 형식은 다를 수 있습니다. 전후방에 대응하는 채널 번호는 확인되지 않아 앱에 원본 채널 번호를 표시합니다.

This macOS app opens recordings from the Smith Club VNB350 dashcam. It lists clips by recording date, plays both channels in sync, and exports a selected channel as MP4. Build with `./build.sh` on macOS 14 or later using Xcode or its Command Line Tools.
