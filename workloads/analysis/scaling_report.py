#!/usr/bin/env python3
"""Summarise repeated scaling runs written by protein/scaling.sh.

Each job's throughput is the dataset's residues over its slowest rank's
forward-pass time (embed.py's timing records). Per node count: mean and
range over the repeats, then speedup and efficiency from the means. With
--sacct, also the share of each job's allocated CPU time its embedding step
(its longest; the dataset check before it takes seconds) used. Runs on the record collect-run.sh harvests, not on the cluster:

  scaling_report.py runs/<name>/jobs/agent/<run-dir> --sacct runs/<name>/slurm/sacct.psv
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Job:
    name: str  # n<nodes>-r<rep>, the job's output directory
    nodes: int
    residues: int
    slowest_seconds: float
    hosts: tuple[str, ...]

    @property
    def residues_per_second(self) -> float:
        return self.residues / self.slowest_seconds


def read_job(out_dir: Path) -> Job:
    """One job from its timing-<rank>.json files; refuses a job with ranks missing."""
    timings = [json.loads(p.read_text()) for p in sorted(out_dir.glob("timing-*.json"))]
    if not timings:
        raise ValueError(f"{out_dir}: no timing records")
    world = timings[0]["world_size"]
    if sorted(t["rank"] for t in timings) != list(range(world)):
        raise ValueError(f"{out_dir}: expected ranks 0..{world - 1}, found {len(timings)} records")
    return Job(
        name=out_dir.name,
        nodes=world,
        residues=sum(t["residues"] for t in timings),
        slowest_seconds=max(t["seconds"] for t in timings),
        hosts=tuple(t["host"] for t in sorted(timings, key=lambda t: t["rank"])),
    )


def slurm_seconds(value: str) -> float:
    """sacct durations: [D-]HH:MM:SS, MM:SS.mmm or HH:MM:SS.mmm."""
    days, _, clock = value.rpartition("-")
    parts = [float(x) for x in clock.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, s = parts
    return (int(days) if days else 0) * 86400 + h * 3600 + m * 60 + s


def cpu_utilisation(sacct_psv: Path) -> dict[str, float]:
    """Job name (esm-scale-<n..-r..>) to TotalCPU / CPUTime of its longest srun step."""
    rows = [line.split("|") for line in sacct_psv.read_text().splitlines()]
    header, body = rows[0], rows[1:]
    col = {name: i for i, name in enumerate(header)}
    names = {r[col["JobID"]]: r[col["JobName"]] for r in body if r[col["JobID"]].isdigit()}
    longest: dict[str, tuple[float, float]] = {}  # name -> (CPUTime, TotalCPU)
    for r in body:
        job, _, step = r[col["JobID"]].partition(".")
        name = names.get(job, "")
        if step.isdigit() and name.startswith("esm-scale-"):
            allocated = slurm_seconds(r[col["CPUTime"]])
            if allocated > longest.get(name, (0.0, 0.0))[0]:
                longest[name] = (allocated, slurm_seconds(r[col["TotalCPU"]]))
    return {name.removeprefix("esm-scale-"): used / alloc for name, (alloc, used) in longest.items()}


def report(jobs: list[Job], cpu: dict[str, float] | None = None) -> str:
    residues = {j.residues for j in jobs}
    if len(residues) != 1:
        raise ValueError(f"jobs embedded different datasets: {sorted(residues)} residues")
    by_nodes: dict[int, list[Job]] = {}
    for j in sorted(jobs, key=lambda j: (j.nodes, j.name)):
        by_nodes.setdefault(j.nodes, []).append(j)
    if 1 not in by_nodes:
        raise ValueError("no one-node runs to measure speedup against")
    base = statistics.mean(j.residues_per_second for j in by_nodes[1])

    lines = [
        f"Dataset: {residues.pop():,} residues. Throughput = residues / slowest rank's forward pass.",
        "",
        "| Nodes | Runs | Residues/s, mean | Range | Speedup | Efficiency"
        + (" | CPU used of allocation |" if cpu else " |"),
        "|---|---|---|---|---|---" + ("|---|" if cpu else "|"),
    ]
    for n, group in by_nodes.items():
        rates = [j.residues_per_second for j in group]
        mean = statistics.mean(rates)
        row = (
            f"| {n} | {len(group)} | {mean:,.0f} | {min(rates):,.0f}–{max(rates):,.0f} "
            f"| {mean / base:.2f}× | {mean / base / n:.0%}"
        )
        if cpu:
            used = [cpu[j.name] for j in group if j.name in cpu]
            lo, hi = (f"{min(used):.0%}", f"{max(used):.0%}") if used else ("n/a", "n/a")
            row += f" | {lo} |" if lo == hi else f" | {lo}–{hi} |"
        else:
            row += " |"
        lines.append(row)

    lines += ["", "| Job | Nodes | Slowest rank (s) | Residues/s | Hosts by rank |", "|---|---|---|---|---|"]
    for group in by_nodes.values():
        for j in group:
            lines.append(
                f"| {j.name} | {j.nodes} | {j.slowest_seconds:,.1f} "
                f"| {j.residues_per_second:,.0f} | {', '.join(j.hosts)} |"
            )
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--sacct", type=Path, help="sacct -P output (collect-run.sh writes slurm/sacct.psv)")
    args = ap.parse_args()
    dirs = sorted(d for d in args.run_dir.iterdir() if d.is_dir() and re.fullmatch(r"n\d+-r\d+", d.name))
    if not dirs:
        raise SystemExit(f"{args.run_dir}: no n<nodes>-r<rep> job directories")
    cpu = cpu_utilisation(args.sacct) if args.sacct else None
    print(report([read_job(d) for d in dirs], cpu))


if __name__ == "__main__":
    main()
