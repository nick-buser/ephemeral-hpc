#!/usr/bin/env python3
"""Data-parallel ESM-2 embedding: each Slurm task embeds its shard of the
dataset and writes shard-<rank>.npz plus a timing record. Launch one task
per node with srun; the shards are balanced by residue count."""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path

import esm
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shard import read_dataset, shard_by_tokens, slurm_placement  # noqa: E402

MODELS = {
    "esm2_t6_8M_UR50D": esm.pretrained.esm2_t6_8M_UR50D,
    "esm2_t12_35M_UR50D": esm.pretrained.esm2_t12_35M_UR50D,
}


def batches(proteins, max_tokens):
    """Group length-sorted sequences so each forward pass stays under max_tokens."""
    batch, longest = [], 0
    for p in sorted(proteins, key=lambda p: len(p.sequence)):
        width = len(p.sequence) + 2  # BOS and EOS tokens
        if batch and max(longest, width) * (len(batch) + 1) > max_tokens:
            yield batch
            batch, longest = [], 0
        batch.append(p)
        longest = max(longest, width)
    if batch:
        yield batch


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", type=Path, default=Path("/shared/data/uniprot_human.tsv"))
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--model", choices=sorted(MODELS), default="esm2_t6_8M_UR50D")
    ap.add_argument("--max-tokens", type=int, default=4096)
    args = ap.parse_args()

    place = slurm_placement()
    torch.set_num_threads(place.cpus)
    device = "cuda" if torch.cuda.is_available() else "cpu"

    mine = shard_by_tokens(read_dataset(args.input), place.world_size)[place.rank]
    model, alphabet = MODELS[args.model]()
    model = model.eval().to(device)
    layer = model.num_layers
    convert = alphabet.get_batch_converter()

    t0 = time.perf_counter()
    accessions, vectors = [], []
    with torch.inference_mode():
        for batch in batches(mine, args.max_tokens):
            _, _, toks = convert([(p.accession, p.sequence) for p in batch])
            reps = model(toks.to(device), repr_layers=[layer])["representations"][layer]
            for i, p in enumerate(batch):
                # mean over residues, excluding BOS/EOS and padding
                vectors.append(reps[i, 1 : len(p.sequence) + 1].mean(0).cpu().numpy())
                accessions.append(p.accession)
    elapsed = time.perf_counter() - t0

    args.out.mkdir(parents=True, exist_ok=True)
    np.savez(
        args.out / f"shard-{place.rank:02d}.npz",
        accession=np.array(accessions),
        embedding=np.stack(vectors).astype(np.float32),
    )
    residues = sum(len(p.sequence) for p in mine)
    timing = {
        "rank": place.rank,
        "world_size": place.world_size,
        "host": socket.gethostname(),
        "device": device,
        "threads": place.cpus,
        "model": args.model,
        "sequences": len(mine),
        "residues": residues,
        "seconds": round(elapsed, 2),
        "residues_per_second": round(residues / elapsed, 1),
    }
    (args.out / f"timing-{place.rank:02d}.json").write_text(json.dumps(timing, indent=2))
    print(json.dumps(timing))


if __name__ == "__main__":
    main()
