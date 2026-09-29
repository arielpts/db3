/// Allocates column widths from measured content and the current viewport.
/// Columns stop at their preferred width, leaving unused space after the grid.
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
        return desired
    }
}
