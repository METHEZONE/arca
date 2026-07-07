# ARCA

THE ZONE의 메인 앱. macOS + iOS + watchOS (SwiftUI 멀티플랫폼).
노트테이킹(Plaud/Granola 대항)에서 시작해 노치 상주 컴패니언·투두 위임(Toss)·ZONE 집중 모드까지.
(구 ArcaVoice — 내부 타깃명/번들ID는 호환성 위해 ArcaVoice/com.thezone.arca.voice 유지)

- **채널 분리 캡처**: 마이크(나) + 시스템 오디오(상대방) 분리 녹음 → 구조적 화자분리, 봇 없음
- **하이브리드 전사**: 녹음 중 온디바이스 실시간 자막 → 종료 후 고품질 최종 패스(무제한 화자분리)
- **Voice-print**: 회의를 거듭할수록 목소리로 사람을 알아봄
- **BYOK**: 내 Anthropic/OpenAI 키, 서버 없음, 로컬+iCloud

## Dev

```sh
brew install xcodegen        # 최초 1회
cd apps/arca
xcodegen generate            # ARCA.xcodeproj 생성
open ARCA.xcodeproj          # 또는 아래 CLI 빌드
xcodebuild -project ARCA.xcodeproj -scheme ArcaVoice -destination 'platform=macOS,arch=arm64' build
cd Packages/ArcaVoiceKit && swift test   # 코어 패키지 테스트
```

요구사항: Xcode 26+, macOS 26+.

설계 문서: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
