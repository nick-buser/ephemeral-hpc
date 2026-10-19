import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from scaling_report import cpu_utilisation, read_job, report, slurm_seconds  # noqa: E402

RESIDUES = 1200


def write_job(root, name, seconds_by_rank):
    out = root / name
    out.mkdir()
    world = len(seconds_by_rank)
    for rank, seconds in enumerate(seconds_by_rank):
        record = {"rank": rank, "world_size": world, "host": f"compute-{rank + 1}",
                  "residues": RESIDUES // world, "seconds": seconds}
        (out / f"timing-{rank:02d}.json").write_text(json.dumps(record))
    return out


def test_throughput_is_set_by_the_slowest_rank(tmp_path):
    job = read_job(write_job(tmp_path, "n2-r1", [5.0, 6.0]))
    assert job.nodes == 2
    assert job.residues == RESIDUES
    assert job.residues_per_second == pytest.approx(RESIDUES / 6.0)


def test_a_job_missing_a_rank_is_refused(tmp_path):
    out = write_job(tmp_path, "n3-r1", [4.0, 4.0, 4.0])
    (out / "timing-01.json").unlink()
    with pytest.raises(ValueError, match="ranks"):
        read_job(out)


def test_speedup_and_efficiency_come_from_the_means(tmp_path):
    jobs = [read_job(write_job(tmp_path, f"n1-r{r}", [s])) for r, s in [(1, 10.0), (2, 12.0)]]
    jobs += [read_job(write_job(tmp_path, f"n2-r{r}", [s, s])) for r, s in [(1, 5.5), (2, 6.5)]]
    table = report(jobs)
    one = (RESIDUES / 10 + RESIDUES / 12) / 2
    two = (RESIDUES / 5.5 + RESIDUES / 6.5) / 2
    row = next(line for line in table.splitlines() if line.startswith("| 2 | 2 |"))
    assert f"{two / one:.2f}×" in row
    assert f"{two / one / 2:.0%}" in row
    assert f"{RESIDUES / 6.5:,.0f}–{RESIDUES / 5.5:,.0f}" in row


def test_runs_over_different_datasets_are_refused(tmp_path):
    a = read_job(write_job(tmp_path, "n1-r1", [10.0]))
    b = read_job(write_job(tmp_path, "n2-r1", [5.0, 5.0]))
    with pytest.raises(ValueError, match="different datasets"):
        report([a, b.__class__(b.name, b.nodes, b.residues + 1, b.slowest_seconds, b.hosts)])


@pytest.mark.parametrize("value, seconds", [
    ("00:00.052", 0.052),
    ("27:25", 1645.0),
    ("01:27:25", 5245.0),
    ("1-02:00:00", 93600.0),
])
def test_sacct_durations(value, seconds):
    assert slurm_seconds(value) == pytest.approx(seconds)


def test_cpu_utilisation_reads_the_embedding_step_not_the_dataset_check(tmp_path):
    psv = tmp_path / "sacct.psv"
    psv.write_text("\n".join([
        "JobID|JobName|TotalCPU|CPUTime",
        "7|esm-scale-n1-r1|30:00.000|00:40:00",
        "7.batch|batch|00:00.050|00:40:00",
        "7.0|esm-python|00:01.500|00:00:04",
        "7.1|esm-python|27:00.000|00:30:00",
        "8|something-else|00:01.000|00:01:00",
        "8.0|esm-python|00:01.000|00:01:00",
    ]))
    assert cpu_utilisation(psv) == {"n1-r1": pytest.approx(0.9)}
