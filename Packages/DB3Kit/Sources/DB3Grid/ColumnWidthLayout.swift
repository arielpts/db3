/// Allocates column widths from measured content and the current viewport.
///
/// The preferred array determines the number of columns. Missing minimums are
/// zero; extra minimums are ignored. Negative/nonfinite minimums become zero,
/// and nonfinite preferred widths become their minimum. An invalid maximum
/// falls back to 1200; a column's minimum always takes precedence over that cap.
/// Negative/nonfinite available widths behave like a zero-width viewport.
enum ColumnWidthLayout {
    static func widths(preferred: [Double], minimum: [Double], available: Double, maximum: Double = 1200) -> [Double] {
        guard !preferred.isEmpty else { return [] }
        let maximum = maximum.isFinite && maximum > 0 ? maximum : 1200
        let available = available.isFinite && available > 0 ? available : 0
        let minima = preferred.indices.map { index -> Double in
            guard minimum.indices.contains(index), minimum[index].isFinite else { return 0 }
            return max(0, minimum[index])
        }
        let caps = minima.map { max($0, maximum) }
        let desired = preferred.indices.map { index -> Double in
            let value = preferred[index].isFinite ? preferred[index] : minima[index]
            return min(caps[index], max(minima[index], value))
        }

        // Normalizing before summing prevents an overflow for large, but finite,
        // inputs. Keep original minima so horizontal overflow preserves them.
        let scale = max(1, available, desired.max() ?? 0)
        let viewport = available / scale
        let minimumTotal = minima.reduce(0) { $0 + $1 / scale }
        guard minimumTotal < viewport else { return minima }
        let preferredTotal = desired.reduce(0) { $0 + $1 / scale }

        if preferredTotal > viewport {
            let fraction = (viewport - minimumTotal) / (preferredTotal - minimumTotal)
            return desired.indices.map { index in
                minima[index] + (desired[index] - minima[index]) * fraction
            }
        }
        guard preferredTotal < viewport else { return desired }

        // Grow every column in proportion to its content width. A zero-width
        // preference gets unit weight so even empty columns can use free space.
        // Process cap thresholds in order, then redistribute the remainder in
        // one pass. This is O(n log n), including when many columns reach a cap.
        let weights = desired.map { max(Double.leastNonzeroMagnitude, ($0 > 0 ? $0 : 1) / scale) }
        let capacities = desired.indices.map { (caps[$0] - desired[$0]) / scale }
        let order = desired.indices.sorted { lhs, rhs in
            let left = capacities[lhs] / weights[lhs]
            let right = capacities[rhs] / weights[rhs]
            return left == right ? lhs < rhs : left < right
        }
        var suffixWeights = Array(repeating: 0.0, count: order.count + 1)
        for position in order.indices.reversed() {
            suffixWeights[position] = suffixWeights[position + 1] + weights[order[position]]
        }

        var result = desired
        var remaining = viewport - preferredTotal
        for position in order.indices {
            let index = order[position]
            let share = remaining * (weights[index] / suffixWeights[position])
            if share >= capacities[index] {
                result[index] = caps[index]
                remaining = max(0, remaining - capacities[index])
            } else {
                for remainingPosition in position..<order.count {
                    let column = order[remainingPosition]
                    let growth = remaining * (weights[column] / suffixWeights[position]) * scale
                    result[column] = min(caps[column], desired[column] + growth)
                }
                break
            }
        }
        return result
    }
}
