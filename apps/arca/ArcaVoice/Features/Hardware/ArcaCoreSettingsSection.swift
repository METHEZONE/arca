#if os(iOS)
import SwiftUI
import ArcaVoiceKit

struct ArcaCoreSettingsSection: View {
    @State private var link = ArcaCoreLink.shared
    @AppStorage("arcaCoreHotspotSSID") private var hotspotSSID = ""
    @State private var hotspotPassword = ""

    var body: some View {
        Section {
            HStack {
                Label(link.deviceName, systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                Text(connectionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(link.state == .ready ? .green : .secondary)
            }

            if let status = link.deviceStatus {
                LabeledContent(L("배터리", "Battery")) {
                    Text(batteryText(status))
                }
                LabeledContent(L("녹음", "Recording")) {
                    Text(status.isRecording
                         ? L("진행 중 · \(duration(status.sessionSeconds))", "Recording · \(duration(status.sessionSeconds))")
                         : L("대기", "Ready"))
                }
                LabeledContent(L("업로드 대기", "Waiting to upload")) {
                    Text(L("\(status.queuedFiles)개", "\(status.queuedFiles) files"))
                }
                LabeledContent("microSD") {
                    Text(status.hasSDCard ? L("정상", "Ready") : L("확인 필요", "Check card"))
                        .foregroundStyle(status.hasSDCard ? Color.primary : Color.red)
                }
            }

            if link.state == .ready {
                HStack {
                    Button(link.deviceStatus?.isRecording == true
                           ? L("녹음 중지", "Stop recording")
                           : L("녹음 시작", "Start recording")) {
                        link.send(link.deviceStatus?.isRecording == true ? .recordStop : .recordToggle)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L("지금 동기화", "Sync now")) { link.send(.syncNow) }
                        .buttonStyle(.bordered)
                    if link.deviceStatus?.isRecording == true {
                        Button {
                            link.send(.mark)
                        } label: {
                            Image(systemName: "bookmark.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L("중요 구간 표시", "Mark highlight"))
                    }
                    Button {
                        link.send(.screenWake)
                    } label: {
                        Image(systemName: "lightbulb")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L("기기 화면 켜기", "Wake device screen"))
                }
            } else {
                Button(L("ARCA Core 다시 찾기", "Find ARCA Core again")) { link.reconnect() }
            }

            Divider()

            TextField(L("iPhone 핫스팟 이름", "iPhone hotspot name"), text: $hotspotSSID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(L("핫스팟 비밀번호", "Hotspot password"), text: $hotspotPassword)
                .textContentType(.password)
            Button(L("이 핫스팟을 기기에 연결", "Connect device to this hotspot")) {
                link.provisionWiFi(ssid: hotspotSSID, password: hotspotPassword)
                hotspotPassword = ""
            }
            .disabled(link.state != .ready || hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let wifi = link.wifiStatus {
                LabeledContent("Wi-Fi") {
                    if wifi.isConnected {
                        Text("\(wifi.ssid)\(wifi.rssi.map { " · \($0)dBm" } ?? "")")
                            .foregroundStyle(.green)
                    } else {
                        Text(wifiStateLabel(wifi.state))
                    }
                }
                if wifi.savedNetworkCount > 0 {
                    Text(L("기기에 저장된 네트워크 \(wifi.savedNetworkCount)개 · SD 카드에는 저장하지 않음",
                           "\(wifi.savedNetworkCount) saved on device · never stored on the SD card"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let completed = link.lastUploadCompletedAt {
                LabeledContent(L("최근 업로드", "Latest upload")) {
                    Text(completed, style: .relative)
                }
            }

            if let error = link.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("ARCA Core")
        } footer: {
            Text(L("iPhone 설정에서 개인용 핫스팟을 켜고 ‘호환성 최대화’를 활성화하세요. 앱이 암호화된 Bluetooth로 정보를 전달하면 기기가 2.4GHz 핫스팟에 직접 연결하고 대기 중인 녹음을 자동 업로드합니다.",
                   "Turn on Personal Hotspot and Maximize Compatibility in iPhone Settings. ARCA sends the credentials over encrypted Bluetooth; the device then joins the 2.4GHz hotspot and uploads queued recordings automatically."))
        }
        .task { link.start() }
    }

    private var connectionLabel: String {
        switch link.state {
        case .bluetoothOff: return L("Bluetooth 꺼짐", "Bluetooth off")
        case .searching: return L("찾는 중", "Searching")
        case .connecting: return L("연결 중", "Connecting")
        case .discovering: return L("준비 중", "Preparing")
        case .ready: return L("연결됨", "Connected")
        case .unavailable(let reason): return reason
        }
    }

    private func batteryText(_ status: ArcaCoreDeviceStatus) -> String {
        let level = status.batteryPercent.map { "\($0)%" } ?? "—"
        return status.charging ? "\(level) · \(L("충전 중", "Charging"))" : level
    }

    private func duration(_ seconds: UInt32) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func wifiStateLabel(_ state: UInt8) -> String {
        switch state {
        case 1: return L("검색 중", "Scanning")
        case 2: return L("네트워크 선택 대기", "Choose a network")
        case 3: return L("검색 실패", "Scan failed")
        case 4: return L("연결 중", "Connecting")
        case 6: return L("연결됐지만 저장 실패", "Connected; save failed")
        case 7: return L("연결 실패 · 이름과 비밀번호 확인", "Failed · check name and password")
        default: return L("연결 대기", "Not connected")
        }
    }
}
#endif
