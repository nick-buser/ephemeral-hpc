#!/usr/bin/env python3
"""Fetch reviewed human proteins from UniProt and label each as enzyme or not
(has an EC number). Writes a TSV the embed and train steps read.

Stdlib only, so it runs before the cluster's Python environment exists."""

from __future__ import annotations

import argparse
import csv
import io
import random
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shard import Protein, write_dataset  # noqa: E402

QUERY = "(reviewed:true) AND (organism_id:9606) AND (length:[50 TO 1000])"
URL = "https://rest.uniprot.org/uniprotkb/stream?" + urllib.parse.urlencode(
    {"format": "tsv", "fields": "accession,ec,sequence", "query": QUERY}
)


def fetch() -> list[Protein]:
    req = urllib.request.Request(URL, headers={"User-Agent": "ephemeral-hpc/0.1"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        text = resp.read().decode()
    rows = csv.DictReader(io.StringIO(text), delimiter="\t")
    return [
        Protein(r["Entry"], int(bool(r["EC number"].strip())), r["Sequence"])
        for r in rows
    ]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=Path("/shared/data/uniprot_human.tsv"))
    ap.add_argument("--limit", type=int, default=6000, help="sample size; 0 keeps all")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    if args.out.exists():
        print(f"{args.out} exists; not refetching")
        return
    proteins = fetch()
    if args.limit and len(proteins) > args.limit:
        proteins = random.Random(args.seed).sample(proteins, args.limit)
    write_dataset(args.out, proteins)
    enzymes = sum(p.is_enzyme for p in proteins)
    print(f"wrote {len(proteins)} proteins ({enzymes} enzymes) to {args.out}")


if __name__ == "__main__":
    main()
