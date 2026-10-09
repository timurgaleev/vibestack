/**
 * Per-invocation USD ceiling. Every paid call (agent run, judge call, spec
 * draft) asks for an allowance first; the allowance is handed to claude as
 * --max-budget-usd. claude checks that flag between turns, so one call can
 * overshoot its allowance by part of a turn; the cap can therefore be exceeded
 * by at most one call's overshoot, never by a run of calls.
 */
export const MIN_CALL_USD = 0.01;

export class Budget {
  spent = 0;
  calls = 0;
  skipped = 0;

  constructor(readonly capUsd: number, readonly perCallUsd: number) {
    if (!(capUsd > 0) || !(perCallUsd > 0)) throw new Error("budget caps must be positive numbers");
  }

  get remaining(): number {
    return Math.max(0, this.capUsd - this.spent);
  }

  /** Allowance for the next call, or null when the cap is reached. */
  allowance(): number | null {
    const left = this.remaining;
    // The epsilon keeps float residue (0.03 - 0.02) from skipping a cent that is there.
    if (left + 1e-9 < MIN_CALL_USD) {
      this.skipped++;
      return null;
    }
    return Math.min(this.perCallUsd, left);
  }

  charge(usd: number) {
    this.calls++;
    this.spent += Number.isFinite(usd) && usd > 0 ? usd : 0;
  }

  /**
   * Charge a finished call. A call that reports no cost (killed at its
   * timeout, crashed, or lost its result line) may still have spent up to
   * its allowance, so the ledger books the whole allowance for it.
   */
  chargeCall(reportedUsd: number, allowance: number) {
    this.charge(Number.isFinite(reportedUsd) && reportedUsd > 0 ? reportedUsd : allowance);
  }

  summary(): string {
    const skipped = this.skipped ? `, ${this.skipped} skipped at the cap` : "";
    return `Spent $${this.spent.toFixed(4)} of the $${this.capUsd.toFixed(2)} cap (${this.calls} paid calls${skipped}).`;
  }
}
