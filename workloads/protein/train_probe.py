#!/usr/bin/env python3
"""Multi-node PyTorch DDP: train a small classifier on ESM-2 embeddings to
predict whether a protein is an enzyme. One srun task per node; gloo over
the VPC on CPU, NCCL when GPUs are present.

The model is deliberately small. What this step exercises is the distributed
plumbing — rendezvous, gradient all-reduce across nodes, sharded sampling —
that a larger GPU run uses unchanged."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.distributed as dist
from sklearn.metrics import roc_auc_score
from torch import nn
from torch.nn.parallel import DistributedDataParallel
from torch.utils.data import DataLoader, DistributedSampler, TensorDataset

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shard import in_test_split, read_dataset, slurm_placement  # noqa: E402


def rendezvous_env(port: int) -> None:
    """torch.distributed's env:// init reads these; derive them from Slurm."""
    place = slurm_placement()
    os.environ.setdefault("RANK", str(place.rank))
    os.environ.setdefault("WORLD_SIZE", str(place.world_size))
    if "MASTER_ADDR" not in os.environ:
        nodelist = os.environ.get("SLURM_JOB_NODELIST")
        first = (
            subprocess.check_output(["scontrol", "show", "hostnames", nodelist], text=True).split()[0]
            if nodelist
            else "127.0.0.1"
        )
        os.environ["MASTER_ADDR"] = first
    os.environ.setdefault("MASTER_PORT", str(port))
    torch.set_num_threads(place.cpus)


def load(embeddings: Path, dataset: Path):
    labels = {p.accession: p.is_enzyme for p in read_dataset(dataset)}
    acc, emb = [], []
    for shard in sorted(embeddings.glob("shard-*.npz")):
        z = np.load(shard)
        acc.extend(z["accession"].tolist())
        emb.append(z["embedding"])
    if not acc:
        raise SystemExit(f"no shard-*.npz under {embeddings}")
    x = np.concatenate(emb)
    y = np.array([labels[a] for a in acc], dtype=np.float32)
    test = np.array([in_test_split(a) for a in acc])
    return x, y, test


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--embeddings", type=Path, default=Path("out"))
    ap.add_argument("--dataset", type=Path, default=Path("/shared/data/uniprot_human.tsv"))
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch-size", type=int, default=64, help="per rank")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--port", type=int, default=29500)
    args = ap.parse_args()

    rendezvous_env(args.port)
    cuda = torch.cuda.is_available()
    dist.init_process_group(backend="nccl" if cuda else "gloo")
    rank, world = dist.get_rank(), dist.get_world_size()
    device = torch.device(f"cuda:{int(os.environ.get('SLURM_LOCALID', 0))}" if cuda else "cpu")

    torch.manual_seed(0)  # identical initial weights on every rank
    x, y, test = load(args.embeddings, args.dataset)
    train_ds = TensorDataset(torch.from_numpy(x[~test]), torch.from_numpy(y[~test]))
    sampler = DistributedSampler(train_ds, num_replicas=world, rank=rank, shuffle=True, seed=0)
    loader = DataLoader(train_ds, batch_size=args.batch_size, sampler=sampler)

    model = nn.Sequential(nn.Linear(x.shape[1], 128), nn.ReLU(), nn.Dropout(0.1), nn.Linear(128, 1))
    model = DistributedDataParallel(model.to(device))
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-2)
    loss_fn = nn.BCEWithLogitsLoss()

    t0 = time.perf_counter()
    for epoch in range(args.epochs):
        sampler.set_epoch(epoch)
        model.train()
        total = torch.zeros(2, device=device)
        for xb, yb in loader:
            opt.zero_grad()
            loss = loss_fn(model(xb.to(device)).squeeze(1), yb.to(device))
            loss.backward()  # DDP all-reduces gradients across nodes here
            opt.step()
            total += torch.tensor([loss.item() * len(yb), len(yb)], device=device)
        dist.all_reduce(total)
        if rank == 0 and (epoch % 5 == 0 or epoch == args.epochs - 1):
            print(f"epoch {epoch:3d} loss {(total[0] / total[1]).item():.4f}", flush=True)
    train_seconds = time.perf_counter() - t0

    if rank == 0:
        model.eval()
        with torch.inference_mode():
            logits = model.module(torch.from_numpy(x[test]).to(device)).squeeze(1).cpu().numpy()
        y_test = y[test]
        metrics = {
            "world_size": world,
            "backend": dist.get_backend(),
            "train_examples": int((~test).sum()),
            "test_examples": int(test.sum()),
            "test_accuracy": round(float(((logits > 0) == (y_test > 0.5)).mean()), 4),
            "test_auroc": round(float(roc_auc_score(y_test, logits)), 4),
            "majority_baseline_accuracy": round(float(max(y_test.mean(), 1 - y_test.mean())), 4),
            "epochs": args.epochs,
            "train_seconds": round(train_seconds, 2),
        }
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "metrics.json").write_text(json.dumps(metrics, indent=2))
        print(json.dumps(metrics))
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
