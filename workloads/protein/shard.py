"""Pure-Python helpers shared by the workload steps: dataset I/O, sharding,
and reading a task's place in the job from Slurm. No torch import, so the
tests run anywhere."""

from __future__ import annotations

import csv
import hashlib
import heapq
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Protein:
    accession: str
    is_enzyme: int
    sequence: str


def read_dataset(path: Path) -> list[Protein]:
    with path.open(newline="") as fh:
        rows = csv.DictReader(fh, delimiter="\t")
        return [Protein(r["accession"], int(r["is_enzyme"]), r["sequence"]) for r in rows]


def write_dataset(path: Path, proteins: list[Protein]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(["accession", "is_enzyme", "length", "sequence"])
        for p in proteins:
            w.writerow([p.accession, p.is_enzyme, len(p.sequence), p.sequence])
    tmp.replace(path)  # atomic, so a concurrent reader never sees half a file


def shard_by_tokens(proteins: list[Protein], n_shards: int) -> list[list[Protein]]:
    """Longest-first greedy assignment to the least-loaded shard.

    Transformer cost grows with sequence length, so balancing residue counts
    (not item counts) is what keeps the slowest node from setting the wall
    time. Deterministic: ties break on accession.
    """
    if n_shards < 1:
        raise ValueError("n_shards must be >= 1")
    shards: list[list[Protein]] = [[] for _ in range(n_shards)]
    heap = [(0, i) for i in range(n_shards)]
    for p in sorted(proteins, key=lambda p: (-len(p.sequence), p.accession)):
        load, i = heapq.heappop(heap)
        shards[i].append(p)
        heapq.heappush(heap, (load + len(p.sequence), i))
    return shards


def in_test_split(accession: str, test_fraction: float = 0.2) -> bool:
    """Stable train/test split keyed on the accession, identical on every rank."""
    h = int.from_bytes(hashlib.sha256(accession.encode()).digest()[:8], "big")
    return h / 2**64 < test_fraction


@dataclass(frozen=True)
class Placement:
    rank: int
    world_size: int
    cpus: int


def slurm_placement(env: dict[str, str] | None = None) -> Placement:
    """This task's rank and world size from srun's environment; a lone
    process outside Slurm is rank 0 of 1."""
    env = dict(os.environ) if env is None else env
    rank = int(env.get("SLURM_PROCID", env.get("RANK", 0)))
    world = int(env.get("SLURM_NTASKS", env.get("WORLD_SIZE", 1)))
    cpus = int(env.get("SLURM_CPUS_PER_TASK", os.cpu_count() or 1))
    if not 0 <= rank < world:
        raise ValueError(f"rank {rank} outside world of {world}")
    return Placement(rank, world, cpus)


def first_host(nodelist: str) -> str:
    """The first hostname in a Slurm hostlist such as "compute-[1-3]",
    "compute-[07,09-12],gpu-1" or "head,compute-2". Rank 0 runs there, so
    it is the rendezvous address. Parsed here because scontrol is not inside
    the container the job runs in."""
    head, _, rest = nodelist.partition("[")
    if not rest or "," in head:
        return nodelist.split(",")[0]
    first = rest.split("]")[0].split(",")[0].split("-")[0]
    return head + first  # keeps zero padding: "07" stays "07"
