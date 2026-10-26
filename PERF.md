# Performance ledger

Measured on an M1, release build, `top -l 4 -s 10` after a fresh launch and 5 s settle.

Idle budget: ~0% CPU, ~30 MB footprint, near-zero idle wakeups. Search budget: guarded by `PerformanceTests` (10k clips < 50 ms).

| Idea | Baseline → Result | Verdict | Why |
|---|---|---|---|
| Row title reads only the first 2,000 chars | 1.33 ms → 0.01 ms per render on a 20 MB clip | kept | Trimming the whole string ran on every list render. |
| Detail preview size check via `utf8.count` | O(n) → O(1) per render | kept | Same class of bug as the title. |
| Skip reloads while the panel is hidden | ~3 ms per 15 s sweep at 10k clips | not done | Inside idle noise (0.0–0.4% CPU either way). |
| Rows take plain values instead of observing state | ~12 visible rows re-render on a toast | not done | No measurable cost; LazyVStack only builds visible rows. |
| Slower clipboard polling (1 s) | 0.5 s poll, idle CPU already ~0% | not done | Halves wakeups but can miss two quick copies. |
