#!/usr/bin/env python3
"""Download pinned public artifacts; never read Hugging Face credentials."""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

MODELS = {
    "4bit": ("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", "6c3ae70858513f1a78e9cdca3cae330d9075cd2a"),
    "bf16": ("Qwen/Qwen3-Embedding-0.6B", "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"),
}
FILES = {
    "model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json",
    "special_tokens_map.json", "vocab.json", "merges.txt", "1_Pooling/config.json",
    "modules.json", "config_sentence_transformers.json", "sentence_bert_config.json",
    "LICENSE", "README.md",
}


def digest(path, lfs):
    if lfs:
        value = hashlib.sha256()
    else:
        value = hashlib.sha1()
        value.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as stream:
        while block := stream.read(8 * 1024 * 1024):
            value.update(block)
    return value.hexdigest()


def install(name, root):
    repo, revision = MODELS[name]
    metadata_url = f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    with urllib.request.urlopen(metadata_url, timeout=60) as response:
        metadata = json.load(response)
    if metadata["sha"] != revision:
        raise ValueError("Model revision mismatch")
    destination = root / name
    destination.mkdir(parents=True, exist_ok=True)
    manifest = []
    for entry in metadata["siblings"]:
        relative = entry["rfilename"]
        if relative not in FILES:
            continue
        lfs = entry.get("lfs")
        expected = lfs["sha256"] if lfs else entry["blobId"]
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or digest(path, lfs) != expected:
            temporary = path.with_name(path.name + ".partial")
            print(f"Downloading {name}/{relative}", flush=True)
            subprocess.run([
                "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                "--connect-timeout", "30", "--max-time", "1800", "--output", str(temporary),
                f"https://huggingface.co/{repo}/resolve/{revision}/{relative}",
            ], check=True)
            if digest(temporary, lfs) != expected:
                temporary.unlink()
                raise ValueError(f"Artifact integrity failure: {relative}")
            temporary.replace(path)
        manifest.append({"file": relative, "bytes": path.stat().st_size, "hash": expected,
                         "algorithm": "sha256" if lfs else "git-blob-sha1"})
    (destination / "prototype-manifest.json").write_text(json.dumps(
        {"repo": repo, "revision": revision, "files": manifest}, indent=2) + "\n")
    print(f"Verified {name}: {len(manifest)} files", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--model", choices=["all", *MODELS], default="all")
    args = parser.parse_args()
    names = list(MODELS) if args.model == "all" else [args.model]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(lambda name: install(name, args.root), names))
