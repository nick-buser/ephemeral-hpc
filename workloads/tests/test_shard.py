import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "protein"))
from shard import (  # noqa: E402
    Protein,
    in_test_split,
    read_dataset,
    shard_by_tokens,
    slurm_placement,
    write_dataset,
)


def proteins(lengths):
    return [Protein(f"P{i:05d}", i % 2, "A" * n) for i, n in enumerate(lengths)]


def test_every_protein_lands_in_exactly_one_shard():
    ps = proteins(range(50, 550, 7))
    shards = shard_by_tokens(ps, 3)
    seen = [p.accession for s in shards for p in s]
    assert sorted(seen) == sorted(p.accession for p in ps)


def test_shards_are_balanced_by_residues_not_count():
    # one long protein and many short ones: equal counts would be badly skewed
    ps = proteins([1000] + [100] * 20)
    loads = [sum(len(p.sequence) for p in s) for s in shard_by_tokens(ps, 3)]
    assert max(loads) - min(loads) <= 100


def test_sharding_is_deterministic():
    ps = proteins([300, 300, 200, 200, 100, 100])
    a = shard_by_tokens(ps, 2)
    b = shard_by_tokens(list(reversed(ps)), 2)
    assert [[p.accession for p in s] for s in a] == [[p.accession for p in s] for s in b]


def test_more_shards_than_proteins_leaves_empty_shards():
    shards = shard_by_tokens(proteins([100, 200]), 4)
    assert sorted(len(s) for s in shards) == [0, 0, 1, 1]


def test_zero_shards_rejected():
    with pytest.raises(ValueError):
        shard_by_tokens(proteins([100]), 0)


def test_split_is_stable_and_near_target():
    accs = [f"Q{i:06d}" for i in range(5000)]
    first = [in_test_split(a) for a in accs]
    assert first == [in_test_split(a) for a in accs]
    assert 0.17 < sum(first) / len(accs) < 0.23


def test_dataset_round_trip(tmp_path):
    ps = proteins([60, 70, 80])
    path = tmp_path / "d.tsv"
    write_dataset(path, ps)
    assert read_dataset(path) == ps


def test_placement_from_slurm_env():
    p = slurm_placement({"SLURM_PROCID": "2", "SLURM_NTASKS": "3", "SLURM_CPUS_PER_TASK": "2"})
    assert (p.rank, p.world_size, p.cpus) == (2, 3, 2)


def test_placement_outside_slurm_is_single_process():
    p = slurm_placement({})
    assert (p.rank, p.world_size) == (0, 1)


def test_placement_rejects_rank_outside_world():
    with pytest.raises(ValueError):
        slurm_placement({"SLURM_PROCID": "3", "SLURM_NTASKS": "3"})
