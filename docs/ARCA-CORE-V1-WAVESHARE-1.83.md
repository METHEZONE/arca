# ARCA Core v1 — Waveshare ESP32-S3-Touch-LCD-1.83 (SKU 32790)

작성: 2026-08-04. v0 (ESP32-C3/S3 + SSD1306 OLED + INMP441 브레드보드)에서 이 보드로 넘어가는 포팅 계획.

---

## 1. 이 보드가 v0보다 좋은 이유

v0에서 제일 고생했던 게 SD카드였다 (`examples/arca-core-v0/05_sd_*` 스케치가 11개나 있는 이유).
이 보드는 그 문제 3개를 하드웨어로 없애준다.

| v0 문제 | 1.83 보드 |
|---|---|
| microSD 모듈 배선/3V3 레벨 문제 → 11개 rescue 스케치 | **온보드 TF 슬롯**, BSP `bsp_sdcard_mount()` 한 줄 |
| INMP441 I2S 마이크 1개, 배선 노이즈 | **온보드 2-mic array + ES7210 ADC + ES8311 코덱**, AEC 회로 포함 |
| 128x64 모노 OLED (얼굴 표현 한계) | **240x284 65K 컬러 IPS + 정전식 터치** |
| 배터리/전원 관리 없음 | **AXP2101 PMU + 3.7V 리튬 배터리 커넥터** (SKU 32790은 배터리 포함) |
| 시간 정보 없음 (녹음 타임스탬프 불가) | **PCF85063 RTC**, 배터리 백업 유지 |
| 모션 트리거 불가 | **QMI8658 6축 IMU** (탭/들어올리기 감지, 걸음수) |
| 버튼 별도 배선 | **BOOT + PWR 사이드 버튼 내장** |
| 스피커 없음 | **ES8311 + 앰프 + MX1.25 스피커 헤더** (스피커는 별매) |

즉 v0의 "브레드보드 + 3D프린트 트레이" 단계를 건너뛰고 바로 **주머니에 넣고 다니는 물건**이 된다.

---

## 2. 확정된 하드웨어 사실

- SoC: ESP32-S3R8, 240MHz 듀얼코어, 512KB SRAM + **8MB PSRAM (OPI)** + **16MB NOR flash**
- 무선: 2.4GHz Wi-Fi b/g/n + BLE 5 (온보드 안테나)
- 화면: 1.83" IPS 240×284, ST7789P (SPI), CST816D 터치 (I2C)
- 오디오: ES8311 코덱 (출력) + ES7210 4ch ADC (마이크/AEC), SMD 마이크 어레이 온보드
- 저장: 온보드 TF(microSD) 슬롯 → BSP가 `/sdcard` 로 마운트
- 전원: AXP2101 PMU, JST 1.2mm 2P 배터리 헤더, 케이스용 권장 배터리 6×25×25mm
- 센서: QMI8658 6축 IMU, PCF85063 RTC
- 버튼: BOOT, PWR (둘 다 프로그래머블)
- 확장: I2C 1ch, UART 1ch, USB 1ch 패드 + GPIO 패드 10개

### 확인된 GPIO (공식 `pin_config.h`)
출처: https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.83 → `examples/arduino/libraries/Mylibrary/pin_config.h`

```c
#define XPOWERS_CHIP_AXP2101
#define LCD_DC 4      #define LCD_CS 5     #define LCD_SCK 6
#define LCD_MOSI 7    #define LCD_RST 38   #define LCD_BL 40
#define IIC_SDA 15    #define IIC_SCL 14
#define TP_RST 39     #define TP_INT 13
```

I2C 버스(SDA 15 / SCL 14) 하나에 AXP2101, CST816D, QMI8658, PCF85063, ES8311, ES7210가 다 붙어있다.

### 전체 GPIO (공식 인터페이스 다이어그램에서 확인)
출처: https://www.waveshare.com/img/devkit/ESP32-S3-Touch-LCD-1.83/ESP32-S3-Touch-LCD-1.83-details-inter.jpg

| 그룹 | 핀 |
|---|---|
| LCD (ST7789P, SPI) | DC=4  CS=5  SCK=6  MOSI=7  RST=38  BL=40 |
| I2C 공용 버스 | SDA=15  SCL=14 (AXP2101 / CST816D / QMI8658 / PCF85063 / ES8311 / ES7210) |
| Touch CST816D | RST=39  INT=13 |
| IMU QMI8658 | INT1=11  INT2=21 |
| RTC PCF85063 | INT=12 |
| I2S 오디오 | MCLK=16  SCLK/BCLK=9  LRCK/WS=45  ASDOUT=10 (마이크 입력)  DSDIN=8 (스피커 출력)  PA_CTRL=46 |
| **TF카드 (SPI 모드)** | **MOSI=1  SCK=2  MISO=3  CS=42** |
| 버튼 | **BOOT=0  PWR=41** |

두 가지가 중요하다:
1. **TF카드가 LCD와 완전히 별개인 SPI 버스에 있다.** 녹음 중 SD 쓰기가 화면 갱신과 경쟁하지 않는다.
   v0에서 SD가 지옥이었던 이유가 여기서 사라진다.
2. **PWR 버튼이 GPIO41로 그냥 읽힌다.** AXP2101 IRQ 레지스터를 안 거쳐도 된다.

그래도 **ESP-IDF를 써야 한다** — ES7210 마이크는 I2C 레지스터 설정을 해줘야 소리가 나오는데,
그 초기화(`bsp_extra_codec_init()`)가 IDF BSP에만 있다. Arduino `pin_config.h`엔 LCD/터치/I2C만 있고
I2S·SD 핀도 없다.

---

## 3. 검증된 BSP API (공식 데모에서 확인)

`examples/esp-idf/05_Spec_Analyzer/main/main.c` + `06_videoplayer/main/main.c` 실제 코드에서 확인:

```c
#include "bsp/esp-bsp.h"
#include "bsp/display.h"
#include "bsp_board_extra.h"   // 보드별 오디오 확장 (레포에서 복사해오면 됨)

// 오디오 (16kHz / 16bit / 2ch 기본값 - bsp_board_extra.h)
bsp_extra_codec_init();
bsp_extra_codec_volume_set(80, NULL);
bsp_extra_codec_set_fs(16000, 16, I2S_SLOT_MODE_MONO);
bsp_extra_i2s_read(buf, len, &bytes_read, portMAX_DELAY);   // 마이크 입력
bsp_extra_i2s_write(buf, len, &bytes_written, portMAX_DELAY); // 스피커 출력

// SD카드
bsp_sdcard_mount();     // -> /sdcard 에 FATFS 마운트
// (06_videoplayer는 재시도 루프를 돈다. 그대로 따라가는 게 안전)

// 화면 + LVGL
bsp_display_start_with_config(&cfg);
bsp_display_backlight_on();
bsp_display_lock(0); /* LVGL 조작 */ bsp_display_unlock();
```

기본 상수 (`bsp_board_extra.h`):
`CODEC_DEFAULT_SAMPLE_RATE 16000`, `BIT_WIDTH 16`, `CHANNEL 2`, `ADC_VOLUME 24.0`, `VOLUME 60`

2채널로 들어오는 건 마이크 어레이라서다. Spec_Analyzer는 `(left+right)/2`로 다운믹스한다.
ARCA Core도 같이 다운믹스해서 모노로 저장하면 용량 절반.

---

## 4. 녹음 저장: SD카드가 필요한가? → 실질적으로 필수

16kHz / 16bit / 모노 WAV = **32 KB/s = 약 115 MB/시간**

| 저장 위치 | 실제 녹음 가능 시간 |
|---|---|
| 16MB flash (펌웨어 제외 약 4MB 여유) | **약 2분** — 불가 |
| 8MB PSRAM (휘발성, LVGL이 일부 사용) | 약 3~4분, 전원 끊기면 소멸 |
| **32GB microSD (WAV)** | **약 277시간 ≈ 11일 연속** |
| 32GB microSD (AAC 32kbps) | 약 2,100시간 |

결론:
- **온보드 TF 슬롯에 microSD 꽂는 게 정답.** FAT32 포맷, Class 10 이상, 32GB 권장(exFAT는 피하기).
- **WAV 그대로** 간다. 서버가 이미 WAV를 받고 있고, 11일치면 충분하다.
- 나중에 시간 더 필요해지면 esp-adf의 **AAC-LC 인코더** (16kHz 모노 16~32kbps, CPU 약 13%).
  Opus는 16kHz 모노 complexity 1에서 CPU 70% 먹어서 SD 쓰기랑 같이 돌리기엔 위험.

### 한 파일 최대 길이 = 제품 결정이 아니라 FAT32의 한계

| | |
|---|---|
| FAT32 단일 파일 상한 | 4 GiB → **36.4시간 연속** |
| 배터리 (300mAh, 화면 OFF) | **4~6시간 추정** |

즉 **배터리가 6번 죽고도 못 채우는 길이**다. 세션 길이는 사실상 무제한이고, 혹시 4GiB에 닿으면
`…_p2.wav`로 자동 롤오버해서 한 샘플도 안 흘린다. 예전에 말한 "30분 상한"은 녹음 제약이 아니라
업로드 제약이었고, 그건 아래에서 따로 해결했다.

---

## 5. 트리거: 확정된 버튼 매핑

**주머니에 넣고 다니는 기기에서 정전식 터치는 오작동 지옥이다.** 옷/손/땀에 계속 눌린다.
그리고 **PWR 버튼 롱프레스는 AXP2101이 물리적으로 전원을 끊는다** — 주머니에서 눌리면 녹음이 죽는다.

가로로 들고 **USB-C와 버튼이 위쪽 엣지**에 오게 하면 (세로 기준 오른쪽 엣지를 위로 = 반시계 90°),
위에서 왼쪽부터 **BOOT · USB-C · PWR** 순서가 된다.

```
        [ BOOT ]        [ USB-C ]        [ PWR ]
     ┌─────────────────────────────────────────────┐
     │  REC ◂            84%  ⇡2            ▸ SYNC │
     │                ●        ●                   │
     │                     ‿                       │
     │             ▁▃▅▇▅▃▁       00:42             │
     └─────────────────────────────────────────────┘
```

| 버튼 | 동작 | 결과 |
|---|---|---|
| **왼쪽 = BOOT (GPIO0)** | **누르고 있기** | 푸시투토크. 누른 동안 녹음, 떼면 정지 |
| | **한 번 클릭** | 긴 세션 시작. 다시 클릭하면 정지 |
| | 세션 중 길게 누르기 | 하이라이트 마커 |
| **오른쪽 = PWR (GPIO41)** | 클릭 | 화면 깨우기 / 얼굴↔스탯 전환 |
| | 더블클릭 | 하이라이트 마커 |
| | 1.2초 홀드 | 지금 클라우드 동기화 |
| | 6초 홀드 | ⚠️ AXP2101이 **하드웨어로** 전원 차단. 펌웨어가 못 막는다 |
| **터치** | 탭 | 깨우기 / 뷰 전환만. 녹음은 절대 시작·정지 못 함 |

**왜 녹음이 오른쪽이 아니라 왼쪽인가.** 푸시투토크는 말하는 동안 계속 누르고 있는 거고,
PWR을 길게 누르면 PMU의 하드웨어 전원 차단에 닿는다. 펌웨어로 무시할 수 없다.
그래서 **푸시투토크는 물리적으로 PWR에 못 올린다.** BOOT는 그냥 GPIO라 그런 게 없다.

**터치는 절대 녹음 안 시킨다.** 정전식 패널은 주머니에서 계속 눌린다. 깨우기와 뷰 전환까지만.

### 프리롤: 버튼이 늦어도 안 놓친다

녹음 안 할 때도 **최근 6초를 PSRAM 링버퍼에 항상 담아둔다.** 버튼을 누른 순간 그 6초가 파일 앞에
붙는다. "아 이거 중요했는데" 하고 뒤늦게 눌러도 이미 한 말이 남는다. 카드에는 누를 때까지 아무것도
안 쓴다.

이래서 펌웨어가 press-down 후 45ms 확인 뒤에 움직인다 — 프리롤이 그 45ms를 이미 덮고 있으니
확인 딜레이가 공짜다. (주머니 오작동으로 긴 녹음이 켜지는 것도 이 45ms 바닥선이 막는다.)

배터리는 대략 300mAh(6×25×25mm) 기준, 화면 OFF + Wi-Fi OFF + I2S 녹음이면 **4~6시간 추정**
(실측 필요). 화면 켜두면 절반 이하. 그래서 상시 캐리 모드에서는 화면을 꺼두는 게 핵심이고,
Type-C 꽂으면 무한 녹음(데스크 모드).

---

## 6. 오프라인 캡처 → Wi-Fi 만나면 업로드 (store-and-forward)

이게 사용자가 원하는 "와이파이 없이 어디서든 녹음, 나중에 클라우드 업로드"의 정확한 구현.

### SD 디렉터리 구조
```
/sdcard/arca/
  queue/     20260804T193210_a1.wav   + .json (deviceId, recordedAt, battery, marked)
  uploaded/  (성공 후 이동, 용량 부족하면 오래된 것부터 삭제)
  failed/    (3회 실패 시)
  config.json  (wifi ssid/pass, ingest url, device token)
```
파일명 타임스탬프는 **PCF85063 RTC**에서. RTC가 AXP2101로 배터리 백업되니 전원 껐다 켜도 시간 유지.
배터리 잔량은 AXP2101 레지스터에서 읽어서 `.json`에 같이 넣는다.

### Vercel 4.5MB 벽 (중요)

`lib/ingest.ts`의 `MAX_RECORDING_BYTES = 100MB`는 **Vercel에서 절대 도달할 수 없다.**
Vercel Functions는 request body를 **4.5MB로 하드캡**하고 올릴 방법이 없다
(vercel.com/docs/functions/limitations#request-body-size). 그래서 새 엔드포인트를 만들었다:

`POST /api/hardware/session/chunk` — 긴 세션을 **100초짜리 독립 WAV 청크(3.2MB)** 여러 개로 올리고,
같은 `sessionId`를 공유한다. 서버(`lib/hardware/session.ts`)가 청크가 도착할 때마다 전사하고,
`final=true` 청크에서 하나의 Memory로 합친다.

부수 효과가 다 좋다:
- 청크마다 OpenAI 오디오 25MB 상한 안에 넉넉히 들어간다
- 연결이 끊겨도 청크 1개만 손실, 세션 전체가 아니다
- 기기가 아직 업로드 중인 동안 전사가 병렬로 돈다

### 기존 엔드포인트 계약 (`app/api/hardware/ingest/route.ts`, 짧은 클립용)
```
POST {ARCA_BASE}/api/hardware/ingest
Header: x-arca-device-token: <HARDWARE_INGEST_TOKEN>   (또는 Authorization: Bearer)
Body: multipart/form-data
  recording   = 파일 (필수, audio/* 또는 application/octet-stream 허용, 최대 100MB)
  deviceId    = "arca-core-v1-01"
  recordedAt  = ISO8601
  battery     = "0.82"
200 → { ok, memoryId, title, createdAt, integrations }
401 토큰 불일치 / 413 100MB 초과 / 415 타입 거부
```
(이 경로는 짧은 푸시투토크 클립에만 쓴다. 긴 세션은 위의 chunk 엔드포인트로.)

### 동기화 로직
1. 부팅 시 / 5분마다 저장된 SSID 스캔 (`WiFi.scanNetworks` 상당) — 없으면 라디오 즉시 OFF (전력)
2. 연결되면 `queue/` 를 오래된 순서로 순회, 1개씩 chunked multipart POST
3. 200 받으면 `uploaded/` 로 이동, 실패 3회면 `failed/`
4. 진행 상황을 화면에 `uploading_cloud` 얼굴로 표시
5. 업로드 중에는 녹음을 멈추지 말 것 — 별 코어로 태스크 분리 (S3는 듀얼코어. 코어0=오디오, 코어1=네트워크/LVGL)

### BLE는 어떻게 하는가

**ESP32-S3는 Bluetooth Classic이 아예 없다.** A2DP·SPP·헤드셋 프로파일 전부 불가, BLE만 된다.
"이어폰처럼 페어링" 경로는 없고, 자체 GATT 서비스를 만들어서 ARCA iOS 앱의 CoreBluetooth로 붙는다.

처리량이 설계를 결정한다. 실측 기준 ESP32-S3↔아이폰 BLE는 **8~50 KB/s**:

| | |
|---|---|
| 16kHz 모노 PCM | 32 KB/s — BLE로는 간당간당 |
| 같은 오디오를 IMA-ADPCM (4:1) | **8 KB/s — 여유** |
| 1시간 백로그 WAV (115MB) | 40KB/s로도 48분 — 안 됨 |

그래서 역할을 나눴다:
- **BLE → 제어 + 상태 + 라이브 오디오 스트리밍.** 폰이 업링크. 어디서든 즉시 캡처.
  프레임은 20ms IMA-ADPCM, 66kbps, 166바이트 (보수적인 185바이트 ATT MTU에도 들어감).
  각 프레임 헤더에 ADPCM 상태 스냅샷(step index + predictor)을 실어서, 인코더는 리셋 안 하고
  디코더만 프레임마다 재시딩한다 → 프레임 하나 유실이 프레임 하나 손실로 끝난다.
  **실측: 상태 유지 34.3dB SNR vs 프레임마다 리셋 16.7dB.**
- **Wi-Fi → 대량 백로그.** `config.json`의 ssid를 **아이폰 개인용 핫스팟**으로 걸면 기기가 LTE로
  큐를 비운다. 앱 코드 0줄, 가장 싼 "어디서나" 경로다.

GATT: 서비스 `7a9c0000-a5c1-4b2e-9d31-0a5c41524341` (끝 4바이트가 ASCII `ARCA`)
| char | 속성 | 내용 |
|---|---|---|
| `0001` STATUS | read + notify(1Hz) | 배터리/상태/큐/세션길이 패킹 구조체 |
| `0002` CTRL | write | 1바이트 커맨드 (녹음/마크/싱크/스트림) |
| `0003` AUDIO | notify | `[seq:u16][flags:u8][stepIdx:u8][predictor:i16][adpcm:160B]` |

iOS 쪽은 `bluetooth-central` UIBackgroundMode 필요. 기기는 연결 안 됐을 때 계속 광고하니
범위에 들어오면 폰이 알아서 재연결한다.

### USB-C 덤프
맥에 꽂으면 바로 빨아가기. v0의 `arca_bridge_to_app.sh` 재활용.

---

## 7. 온디바이스 대화는? — 솔직한 한계

| 기능 | ESP32-S3에서 가능? | 근거 |
|---|---|---|
| 웨이크워드 감지 (오프라인) | **가능** — WakeNet9, 16KB RAM + 324KB PSRAM, 32ms 프레임당 3ms | Espressif ESP-SR |
| 고정 명령어 인식 (오프라인, 최대 300개) | **가능** — MultiNet | ESP-SR |
| **한국어** 웨이크워드/명령어 | **불가** — 중/영/일/불만 지원, 한국어는 로드맵 상태 | esp-sr issue #88 |
| 자유 음성 → 텍스트 (STT) 온디바이스 | **불가** — Whisper tiny만 75MB+, RAM 300MB 필요 | 물리적으로 안 들어감 |
| LLM 온디바이스 대화 | **실질 불가** — 최대 28.9M 파라미터(4bit, 14.9MB flash), 9~30 tok/s, TinyStories 수준 | DaveBben/esp32-llm |

**따라서 현실적 아키텍처는 이렇게 갈라진다:**

- **오프라인(항상)**: 마이크 캡처 + VAD 게이트 + 타임스탬프 + SD 저장 + 얼굴 애니메이션 + 버튼/IMU 반응.
  영어 웨이크워드("hey arca")까지는 오프라인으로 가능.
- **온라인(Wi-Fi 또는 BLE 테더링)**: STT + LLM 추론 + 대화 응답(ES8311 스피커로 TTS 재생).

즉 **"온디바이스 대화"는 안 되지만 "온디바이스 캡처 + 온라인 두뇌"는 완전히 된다.** 그리고 ARCA의
가치 제안(맥락 축적 → 디지털 트윈)에는 그게 맞다. 기기가 혼자 똑똑할 필요가 없고, 놓치지 않고
기억하는 게 핵심이니까.

참고로 **xiaozhi-esp32** (https://github.com/78/xiaozhi-esp32) 가 정확히 이 구조를 오픈소스로
구현해놨다 — 온디바이스 웨이크워드 + WebSocket으로 클라우드 LLM 스트리밍, 한국어 지원,
자체 서버(`xinnan-tech/xiaozhi-esp32-server`)도 가능. 이 1.83 보드는 프리셋에 없지만
Waveshare AMOLED 1.8/2.06/2.16은 지원하고 같은 ES8311/ES7210 조합이라 포팅 난이도가 낮다.
**대화 기능은 바닥부터 만들지 말고 여기서 포팅해오는 게 맞다.**

---

## 8. 오늘 당장 할 순서

1. **USB-C 연결** → 공장 데모 부팅되는지 확인 (화면 켜지면 하드웨어 정상)
2. **microSD를 FAT32로 포맷**해서 꽂기 (32GB 이하, Class 10)
3. **ESP-IDF 5.5 + VS Code Espressif 확장** 설치 (Arduino 아님 — 오디오 코덱 때문)
4. 공식 레포 clone → `examples/esp-idf/05_Spec_Analyzer` 빌드/플래시
   → **말했을 때 스펙트럼이 움직이면 마이크 검증 완료**
5. `examples/esp-idf/06_videoplayer` 빌드/플래시
   → **"SD card mounted successfully" 로그 뜨면 SD 검증 완료**
6. `examples/esp-idf/01_AXP2101` → 배터리 잔량/PWR키 IRQ 읽는 법 확인
7. 위 3개를 합쳐서 `firmware/arca-core-v1/` 새 IDF 프로젝트 생성:
   - `bsp_extra_codec_init()` + `bsp_extra_i2s_read()` → PSRAM 링버퍼
   - VAD 게이트 → `/sdcard/arca/queue/*.wav` (30분 롤오버)
   - BOOT 버튼 인터럽트 → 토글/마킹
   - Wi-Fi 있으면 `/api/hardware/ingest` 로 큐 업로드
   - LVGL로 `hardware/arca-qbit-facepack/` 얼굴 8종 표시 (240×284 컬러니까 v0 모노 OLED보다 훨씬 좋음)

포팅 소스로 쓸 v0 코드:
- `examples/arca-core-v0/07_record_wav/` — WAV 헤더 작성 + I2S→SD 쓰기
- `examples/arca-core-v0/10_sta_record_upload/` — `/api/hardware/ingest` multipart POST
- `examples/arca-core-v0/09_expo_sd_wifi_fallback/` — SD 실패 시 RAM 폴백 + AP 모드로 파일 노출
- `examples/arca-core-v0/14_button_oled_face_mvp/` — 버튼 → 얼굴 상태머신

## 9. 구현 상태 (2026-08-04)

**`firmware/arca-core-v1/` 에 ESP-IDF 프로젝트로 실제로 작성됨** — 24개 파일, 약 2,900줄.

| 파일 | 역할 |
|---|---|
| `arca_config.h` | 전체 튜너블 + 보드 핀맵 |
| `arca_main.c` | init 순서 + 녹음 상태를 소유하는 단일 이벤트 루프 |
| `arca_buttons.c` | 두 버튼의 hold-vs-click 상태머신 |
| `arca_recorder.c` | I2S 캡처, 프리롤, PSRAM 링, WAV 세션 라이터 |
| `arca_storage.c` | SD 마운트, 큐 디렉터리, 공간 회수, 전원 손실 복구 |
| `arca_uploader.c` | Wi-Fi 버스트 + 스트리밍 chunked multipart POST |
| `arca_face.c` | LVGL 가로 얼굴 8종 + 백라이트 정책 |
| `arca_ble.c` | NimBLE GATT: 상태 / 제어 / ADPCM 라이브 오디오 |
| `arca_power.c` | AXP2101 연료계 |
| `arca_wav.c` | RIFF 헤더 작성/패치/크래시 복구 |
| `arca_adpcm.c` | IMA-ADPCM 인코더 (BLE 전용, 파일은 PCM 유지) |
| `arca_clock.c` | PCF85063 RTC 타임스탬프 + SNTP 보정 |

서버 쪽: `lib/hardware/session.ts` + `app/api/hardware/session/chunk/route.ts` 신규.
`npx tsc --noEmit` 통과.

**아직 안 된 것:** 이 머신에 ESP-IDF가 없어서 **컴파일 검증을 못 했다.** Waveshare 공식 데모가
실제로 쓰는 BSP API(`bsp_extra_codec_init`, `bsp_extra_i2s_read`, `bsp_sdcard_mount`,
`bsp_display_start_with_config`)에 맞춰 썼지만, 첫 `idf.py build`에서 include 경로와
BSP 접근자 이름 몇 개는 고쳐야 할 것으로 예상. ADPCM 인코더와 WAV 라이터는 독립 디코더를 만들어
Python으로 교차검증했고(라운드트립 SNR 34.3dB, 헤더 패치·크래시 복구 통과), clang 경고 0으로 컴파일된다.

## 10. 법적 참고
한국 통신비밀보호법 제3조는 **본인이 대화 당사자가 아닌** 대화의 녹음을 금지한다. 본인이 참여한
대화의 녹음은 상대 동의 없이도 합법 (대법원 판례 일관). 즉 상시 캐리 녹음 자체는 문제 없다.
단, 본인이 없는 자리에 기기를 놓고 녹음하는 기능은 절대 만들지 말 것.
