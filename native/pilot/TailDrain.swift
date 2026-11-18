import Foundation

enum TailDrainDecision: Equatable { case wait, finish, timeout }

// Idle proves the recorder stopped, not that the stream has finished arriving.
// Keep the original 350 ms minimum / 250 ms quiet / 1 s absolute budget.
func tailDrainDecision(elapsed: Double, quiet: Double, pending: Int,
                       lastFlag: Bool, terminalMatched: Bool, unparsed: Int) -> TailDrainDecision {
    guard elapsed.isFinite, quiet.isFinite, elapsed >= 0, quiet >= 0,
          pending >= 0, unparsed >= 0 else { return .timeout }
    // A delayed callback must not turn evidence arriving beyond the absolute
    // budget into success just because all conditions happen to be true now.
    guard elapsed <= 1 else { return .timeout }
    if elapsed >= 0.35, quiet >= 0.25, pending == 0,
       lastFlag, terminalMatched, unparsed == 0 { return .finish }
    return elapsed >= 1 ? .timeout : .wait
}
