# Verifying audit-4410fec

The tag `audit-4410fec` publishes the contracts at commit `4410fecd8997c912ae8861a337e47bfa0c5af6e3` of our private repository `metric-core`. That commit is the version named in:

- **Zellic re-audit, September 2026** (`OMM Reaudit - Zellic Audit Report.pdf`, p. 10: "Only changes between 33d0a34...4410fec")
- **Sherlock bug bounty contest, September 2026** (`2026.09.15 - Final - Metric Public Bug Bounty Audit Contest Report`, p. 2: "FinalCommit: 4410fecd89…")

The public tag is a new commit without the private history, so its own hash is not `4410fec`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `4410fec…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `4410fecd8997c912ae8861a337e47bfa0c5af6e3`, the hash in the reports.
2. `commit.raw` names root tree `a95f1d09ff47f3511eb9f80a24f854e4b1c153d4`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `3c289ab9536fb1296fecb72d9ae43b10b0a67f92`.
4. In the public tag, `contracts/` must hash to the same `3c289ab9536fb1296fecb72d9ae43b10b0a67f92`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-4410fec https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 4410fecd8997c912ae8861a337e47bfa0c5af6e3
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 4410fecd8997c912ae8861a337e47bfa0c5af6e3
git hash-object -t tree verify/tree.raw       # a95f1d09ff47f3511eb9f80a24f854e4b1c153d4
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree a95f1d09ff47f3511eb9f80a24f854e4b1c153d4 contracts   # ... tree 3c289ab9536fb1296fecb72d9ae43b10b0a67f92  contracts
git rev-parse HEAD:contracts              # 3c289ab9536fb1296fecb72d9ae43b10b0a67f92
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
