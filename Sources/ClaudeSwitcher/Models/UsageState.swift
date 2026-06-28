struct UsageWindow {
    let label: String
    let percent: Double
    let resetsIn: String?
}

struct UsageState {
    let available: Bool
    let display: String
    let windows: [UsageWindow]

    init(available: Bool, display: String, windows: [UsageWindow] = []) {
        self.available = available
        self.display = display
        self.windows = windows
    }

    var maxPercent: Double? {
        windows.map(\.percent).max()
    }

    func isExhausted(threshold: Double = 100.0) -> Bool {
        guard let max = maxPercent else { return false }
        return max >= threshold
    }
}
