import Foundation
import ArcaVoiceCore

/// Failures the vitals feature reports to the user. Deliberately few and
/// specific — "couldn't read your body data" with no reason is the kind of
/// message that makes people turn a health feature off.
public enum VitalsError: Error, LocalizedError, Equatable, Sendable {
    /// HealthKit doesn't exist here — the Mac, or a device with health data off.
    case healthUnavailable
    /// The user hasn't granted Health access yet.
    case notAuthorized
    /// A meal arrived with no calories and no macros.
    case nothingToWrite
    /// The Watch measurement ended before it collected a usable heart rate.
    case measurementTooShort

    public var errorDescription: String? {
        switch self {
        case .healthUnavailable:
            return L("이 기기에서는 Apple 건강 데이터를 쓸 수 없어요. 아이폰이나 애플워치에서 측정됩니다.",
                     "Apple Health data isn't available on this device. Measuring happens on your iPhone or Apple Watch.")
        case .notAuthorized:
            return L("건강 데이터 접근 권한이 필요해요. 설정 → 바이탈에서 허용해 주세요.",
                     "ARCA needs access to your health data. Allow it in Settings → Vitals.")
        case .nothingToWrite:
            return L("기록할 칼로리나 영양 정보가 없었어요.",
                     "There were no calories or nutrition details to log.")
        case .measurementTooShort:
            return L("측정 시간이 너무 짧아 심박을 충분히 모으지 못했어요. 30초 이상 유지해 주세요.",
                     "That was too short to gather enough heartbeats. Hold it for at least 30 seconds.")
        }
    }
}
