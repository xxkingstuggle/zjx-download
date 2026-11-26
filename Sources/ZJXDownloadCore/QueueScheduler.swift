import Foundation

@MainActor
public final class QueueScheduler {
    public var onStartQueue: ((Int64) -> Void)?
    public var onStopQueue: ((Int64) -> Void)?
    private var firedEvents = Set<String>()
    private var lastMinuteStamp = ""

    public init() {}

    public func tick(queues: [QueueRecord], now: Date = .now, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return }
        let productWeekday = weekday == 1 ? 7 : weekday - 1
        let minuteStamp = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)-\(hour)-\(minute)"
        if minuteStamp != lastMinuteStamp {
            firedEvents.removeAll(keepingCapacity: true)
            lastMinuteStamp = minuteStamp
        }
        for queue in queues {
            let currentMinute = hour * 60 + minute
            let startMinute = queue.schedule.startHour * 60 + queue.schedule.startMinute
            let stopMinute = queue.schedule.stopHour * 60 + queue.schedule.stopMinute
            if queue.schedule.days.contains(productWeekday), queue.schedule.startEnabled,
               startMinute == currentMinute, !queue.isRunning {
                let key = eventKey(queue.id, "start", parts)
                if firedEvents.insert(key).inserted { onStartQueue?(queue.id) }
            }
            let stopDay = queue.schedule.startEnabled && queue.schedule.stopEnabled && stopMinute < startMinute
                ? (productWeekday == 1 ? 7 : productWeekday - 1) : productWeekday
            if queue.schedule.days.contains(stopDay), queue.schedule.stopEnabled,
               stopMinute == currentMinute, queue.isRunning {
                let key = eventKey(queue.id, "stop", parts)
                if firedEvents.insert(key).inserted { onStopQueue?(queue.id) }
            }
        }
    }

    public func nextEvent(for queue: QueueRecord, after date: Date = .now, calendar: Calendar = .current) -> (kind: String, date: Date)? {
        var candidates: [(String, Date)] = []
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { continue }
            let weekdayValue = calendar.component(.weekday, from: day)
            let weekday = weekdayValue == 1 ? 7 : weekdayValue - 1
            if queue.schedule.days.contains(weekday), queue.schedule.startEnabled,
               let value = calendar.date(bySettingHour: queue.schedule.startHour, minute: queue.schedule.startMinute, second: 0, of: day), value > date {
                candidates.append(("开始", value))
            }
            let startMinute = queue.schedule.startHour * 60 + queue.schedule.startMinute
            let stopMinute = queue.schedule.stopHour * 60 + queue.schedule.stopMinute
            let stopDay = queue.schedule.startEnabled && queue.schedule.stopEnabled && stopMinute < startMinute
                ? (weekday == 1 ? 7 : weekday - 1) : weekday
            if queue.schedule.days.contains(stopDay), queue.schedule.stopEnabled,
               let value = calendar.date(bySettingHour: queue.schedule.stopHour, minute: queue.schedule.stopMinute, second: 0, of: day), value > date {
                candidates.append(("停止", value))
            }
        }
        return candidates.min(by: { $0.1 < $1.1 }).map { ($0.0, $0.1) }
    }

    private func eventKey(_ queueID: Int64, _ action: String, _ date: DateComponents) -> String {
        "\(queueID)-\(action)-\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)-\(date.hour ?? 0)-\(date.minute ?? 0)"
    }
}
