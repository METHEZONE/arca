import Foundation

/// Renders vitals as text for the model — a compact block that rides every chat
/// turn, and a fuller week's context for the coach.
///
/// Both are built here rather than at the call sites so the numbers ARCA says
/// out loud can never drift from the numbers on screen.
public enum VitalsPrompt {
    /// Injected into the chat system prompt so "지금 내 컨디션 어때?" is answered
    /// from real measurements instead of a guess. Empty when there's nothing
    /// measured — an empty block is better than a block full of "unknown".
    public static func chatBlock(today: DailyVitals?, windows: [FocusWindow],
                                 now: Date = .now, calendar: Calendar = .current) -> String {
        guard let today, !(today.metrics.isEmpty && today.scores.isEmpty) else { return "" }

        var lines: [String] = []
        if let readiness = today.scores.readiness {
            lines.append("- 몰입 준비도 \(readiness)/100 (\(VitalsScoring.readinessLabel(readiness)))")
        }
        if let stress = today.scores.stress {
            lines.append("- 스트레스 \(stress)/100 (\(VitalsScoring.stressLabel(stress)))")
        }
        if let sleepScore = today.scores.sleep, let sleep = today.metrics.sleep {
            lines.append("- 어젯밤 수면 \(sleep.durationLabel), 점수 \(sleepScore)/100")
        }
        if let live = today.scores.liveFocus {
            lines.append("- 방금 측정한 몰입 깊이 \(live)/100")
        }
        if let hrv = today.metrics.meanHRV {
            lines.append("- 오늘 HRV 평균 \(Int(hrv))ms")
        }
        if let resting = today.metrics.restingHeartRate {
            lines.append("- 안정심박 \(Int(resting))bpm")
        }
        if let energy = today.metrics.dietaryEnergyKcal, energy > 0 {
            lines.append("- 오늘 섭취 \(Int(energy))kcal (건강 앱 합계)")
        } else if today.loggedCalories > 0 {
            lines.append("- 오늘 ARCA에 기록된 섭취 \(Int(today.loggedCalories))kcal")
        }
        if !today.meals.isEmpty {
            let meals = today.meals
                .sorted { $0.at < $1.at }
                .map { "\(timeLabel($0.at, calendar: calendar)) \($0.label) \(Int($0.calories))kcal" }
                .joined(separator: ", ")
            lines.append("- 오늘 식사: \(meals)")
        }
        if !today.scores.drivers.isEmpty {
            lines.append("- 근거: " + today.scores.drivers.joined(separator: " / "))
        }
        if let next = ChronotypeProfile.nextWindow(after: now, windows: windows, calendar: calendar) {
            lines.append("- 다음 몰입 골든타임: \(next.label)")
        }

        guard !lines.isEmpty else { return "" }
        return """


        The user's body right now, measured from Apple Health. Use these numbers \
        when they ask about their condition, focus, sleep, stress, or food, and \
        say the actual figures — never invent one that isn't listed here. If \
        something they ask about is absent, say it isn't measured yet:
        \(lines.joined(separator: "\n"))
        """
    }

    /// The week of context the coach reasons over.
    public static func coachContext(days: [DailyVitals], windows: [FocusWindow],
                                    calendar: Calendar = .current) -> String {
        let ordered = days.sorted { $0.day < $1.day }
        var sections: [String] = []

        var dayLines: [String] = []
        for day in ordered.suffix(14) {
            var parts: [String] = [day.day]
            if let sleep = day.metrics.sleep, sleep.asleepMinutes > 0 {
                var sleepPart = "수면 \(sleep.durationLabel)"
                if let bedtime = sleep.bedtime {
                    sleepPart += " (취침 \(timeLabel(bedtime, calendar: calendar))"
                    if let wake = sleep.wakeTime {
                        sleepPart += ", 기상 \(timeLabel(wake, calendar: calendar))"
                    }
                    sleepPart += ")"
                }
                if sleep.hasStages {
                    sleepPart += " 깊은 \(sleep.deepMinutes)분 / REM \(sleep.remMinutes)분"
                }
                if sleep.awakenings > 0 {
                    sleepPart += " 깬 횟수 \(sleep.awakenings)"
                }
                parts.append(sleepPart)
            }
            if let score = day.scores.sleep { parts.append("수면점수 \(score)") }
            if let hrv = day.metrics.meanHRV { parts.append("HRV \(Int(hrv))ms") }
            if let resting = day.metrics.restingHeartRate { parts.append("안정심박 \(Int(resting))") }
            if let stress = day.scores.stress { parts.append("스트레스 \(stress)") }
            if let readiness = day.scores.readiness { parts.append("준비도 \(readiness)") }
            if let exercise = day.metrics.exerciseMinutes, exercise > 0 {
                parts.append("운동 \(exercise)분")
            }
            if let energy = day.metrics.dietaryEnergyKcal, energy > 0 {
                parts.append("섭취 \(Int(energy))kcal")
            }
            let focusMinutes = day.focusSessions.reduce(0) { $0 + $1.minutes }
            if focusMinutes > 0 {
                let interrupted = day.focusSessions.reduce(0) { $0 + $1.interruptedCount }
                parts.append("몰입 \(focusMinutes)분(끊김 \(interrupted)회)")
            }
            dayLines.append("- " + parts.joined(separator: " · "))
        }
        if !dayLines.isEmpty {
            sections.append("## 최근 기록\n" + dayLines.joined(separator: "\n"))
        }

        let peaks = ChronotypeProfile.best(windows, count: 5)
        if !peaks.isEmpty {
            let peakLines = peaks.map {
                "- \($0.label): 상대강도 \(Int($0.score * 100))%, 관측 \($0.minutesObserved)분"
            }
            sections.append("## 시간대별 몰입 강도 (본인 최고 시간 = 100%)\n"
                            + peakLines.joined(separator: "\n"))
        } else {
            sections.append("## 시간대별 몰입 강도\n- 아직 데이터 부족")
        }

        let deepMeasures = ordered.flatMap(\.deepMeasures).sorted { $0.startedAt < $1.startedAt }
        if !deepMeasures.isEmpty {
            let measureLines = deepMeasures.suffix(8).map { measure in
                var line = "- \(measure.startedAt.formatted(date: .abbreviated, time: .shortened)):"
                line += " 깊이 \(measure.focusDepth), 평균심박 \(Int(measure.meanHR))bpm"
                if let hrv = measure.hrvSDNN { line += ", HRV \(Int(hrv))ms" }
                return line
            }
            sections.append("## 직접 측정한 몰입 세션\n" + measureLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    static func timeLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
