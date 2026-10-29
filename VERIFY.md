# Verifying audit-7b9ab56

The tag `audit-7b9ab56` publishes the contracts at commit `7b9ab567631a234ba5d467c646a1da9cbfb25479` of our private repository `metric-core`. That commit is the version named in:

- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 2: "FinalCommit: 7b9ab56763…")
- **Sherlock bug bounty contest, September 2026** (`2026.09.15 - Final - Metric Public Bug Bounty Audit Contest Report`, p. 2: "AuditedCommit: 7b9ab56763…")

The public tag is a new commit without the private history, so its own hash is not `7b9ab56`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `7b9ab56…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `7b9ab567631a234ba5d467c646a1da9cbfb25479`, the hash in the reports.
2. `commit.raw` names root tree `e33d7a523d6f800ce99cfc3d5fe34fe5ad1f608b`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `b8b61255c99811f2bbd81d0e3d588446cc01c7b4`.
4. In the public tag, `contracts/` must hash to the same `b8b61255c99811f2bbd81d0e3d588446cc01c7b4`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-7b9ab56 https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 7b9ab567631a234ba5d467c646a1da9cbfb25479
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 7b9ab567631a234ba5d467c646a1da9cbfb25479
git hash-object -t tree verify/tree.raw       # e33d7a523d6f800ce99cfc3d5fe34fe5ad1f608b
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree e33d7a523d6f800ce99cfc3d5fe34fe5ad1f608b contracts   # ... tree b8b61255c99811f2bbd81d0e3d588446cc01c7b4  contracts
git rev-parse HEAD:contracts              # b8b61255c99811f2bbd81d0e3d588446cc01c7b4
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
