import Foundation

/// What ARCA actually did for the user over a stretch of days.
///
/// This is the product's core promise turned into arithmetic, and it is
/// deliberately conservative about what it claims.
///
/// The tempting number is "ARCA gave you back 4 hours" — absorbed interruptions
/// multiplied by some cost-per-interruption. There is no honest constant for
/// that: the widely-quoted context-switch figures are averages across unrelated
/// study populations, and multiplying by one would manufacture a headline number
/// with nothing behind it. So the ledger reports facts it can actually stand on:
/// how long the user was in the ZONE, how many things ARCA handled so they never
/// arrived, and how many still needed the human. The last pair is the real story
/// anyway — it's exactly the "you become the bottleneck" problem, measured.
public struct FocusLedger: Equatable, Sendable {
    /// Number of calendar days the ledger covers.
    public var days: Int
    /// Minutes spent in declared focus sessions.
    public var zoneMinutes: Int
    public var sessionCount: Int
    /// Incoming items ARCA handled on the user's behalf during those sessions.
    public var absorbed: Int
    /// Items that still needed a human decision.
    public var escalated: Int
    /// Tasks ARCA carried all the way to done.
    public var loopsClosed: Int
    /// The day with the most focus, when there is one.
    public var bestDay: BestDay?

    public struct BestDay: Equatable, Sendable {
        public var day: String
        public var minutes: Int

        public init(day: String, minutes: Int) {
            self.day = day
            self.minutes = minutes
        }
    }

    public init(days: Int, zoneMinutes: Int, sessionCount: Int, absorbed: Int,
                escalated: Int, loopsClosed: Int, bestDay: BestDay? = nil) {
        self.days = days
        self.zoneMinutes = zoneMinutes
        self.sessionCount = sessionCount
        self.absorbed = absorbed
        self.escalated = escalated
        self.loopsClosed = loopsClosed
        self.bestDay = bestDay
    }

    public static let empty = FocusLedger(days: 0, zoneMinutes: 0, sessionCount: 0,
                                          absorbed: 0, escalated: 0, loopsClosed: 0)

    /// True when there is nothing worth showing yet.
    public var isEmpty: Bool {
        zoneMinutes == 0 && absorbed == 0 && escalated == 0 && loopsClosed == 0
    }

    /// Share of interruptions ARCA kept off the user's desk, 0–1. Nil when
    /// nothing came in at all — a shield with nothing to block has no score.
    public var absorbRate: Double? {
        let total = absorbed + escalated
        guard total > 0 else { return nil }
        return Double(absorbed) / Double(total)
    }

    /// Average length of a focus session, which is the number that actually
    /// moves when the product is working.
    public var averageSessionMinutes: Int? {
        guard sessionCount > 0 else { return nil }
        return Int((Double(zoneMinutes) / Double(sessionCount)).rounded())
    }
}

/// Change between two periods, so the user sees a direction and not just a total.
public struct FocusLedgerTrend: Equatable, Sendable {
    public var current: FocusLedger
    public var previous: FocusLedger

    public init(current: FocusLedger, previous: FocusLedger) {
        self.current = current
        self.previous = previous
    }

    public var minutesDelta: Int { current.zoneMinutes - previous.zoneMinutes }

    /// Percent change in focus time. Nil when the previous period had none —
    /// "up ∞%" from zero is not information.
    public var minutesDeltaPercent: Int? {
        guard previous.zoneMinutes > 0 else { return nil }
        return Int(((Double(current.zoneMinutes) - Double(previous.zoneMinutes))
                    / Double(previous.zoneMinutes) * 100).rounded())
    }

    public var isImproving: Bool { minutesDelta > 0 }

    /// True only when there's a real basis for comparison.
    public var hasComparison: Bool { !previous.isEmpty }
}

public enum FocusLedgerBuilder {
    /// Builds a ledger from the focus sessions recorded in day files.
    ///
    /// `loopsClosed` is passed in rather than derived here because the task store
    /// lives in a different module; the caller counts tasks it ran to completion
    /// inside the same window.
    public static func build(days vitals: [DailyVitals],
                             loopsClosed: Int = 0) -> FocusLedger {
        let sessions = vitals.flatMap(\.focusSessions)
        guard !sessions.isEmpty || loopsClosed > 0 else {
            return FocusLedger(days: vitals.count, zoneMinutes: 0, sessionCount: 0,
                               absorbed: 0, escalated: 0, loopsClosed: loopsClosed)
        }

        var minutesByDay: [String: Int] = [:]
        for day in vitals {
            let minutes = day.focusSessions.reduce(0) { $0 + $1.minutes }
            if minutes > 0 { minutesByDay[day.day] = minutes }
        }
        // Ties go to the more recent day: "your best day was yesterday" lands
        // better than "your best day was last Tuesday" when they're equal.
        let best = minutesByDay
            .max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }
            .map { FocusLedger.BestDay(day: $0.key, minutes: $0.value) }

        return FocusLedger(
            days: vitals.count,
            zoneMinutes: sessions.reduce(0) { $0 + $1.minutes },
            sessionCount: sessions.count,
            absorbed: sessions.reduce(0) { $0 + $1.handledCount },
            escalated: sessions.reduce(0) { $0 + $1.interruptedCount },
            loopsClosed: loopsClosed,
            bestDay: best)
    }

    /// Splits a run of day files into "this week" and "the week before" and
    /// builds both, so the UI can show a direction.
    ///
    /// `vitals` must be ordered oldest → newest, which is what the store
    /// guarantees.
    public static func trend(days vitals: [DailyVitals],
                             window: Int = 7,
                             loopsClosedCurrent: Int = 0,
                             loopsClosedPrevious: Int = 0) -> FocusLedgerTrend {
        let current = Array(vitals.suffix(window))
        let previous = Array(vitals.dropLast(current.count).suffix(window))
        return FocusLedgerTrend(
            current: build(days: current, loopsClosed: loopsClosedCurrent),
            previous: build(days: previous, loopsClosed: loopsClosedPrevious))
    }
}
