# Verifying audit-d4d0e2a

The tag `audit-d4d0e2a` publishes the contracts at commit `d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575` of our private repository `metric-core`.

No report names this commit itself. It is the `lib/metric-core` dependency of periphery commits `378a748` and `ed58520`, the Sherlock periphery update review's audited and final commits (`2026.10.10 - Final - Metric Collaborative Audit Report`, p. 2), published as tags [`audit-378a748`](https://github.com/Metricxyz/periphery-contracts/tree/audit-378a748) and [`audit-ed58520`](https://github.com/Metricxyz/periphery-contracts/tree/audit-ed58520).

The public tag is a new commit without the private history, so its own hash is not `d4d0e2a`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `d4d0e2a…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575`, the commit pinned as `lib/metric-core`.
2. `commit.raw` names root tree `d93d081406eb2f1fcb7769269cc16512da291616`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `77ccd4f0bbc452ed47f3aa6394e23b90037c241a`.
4. In the public tag, `contracts/` must hash to the same `77ccd4f0bbc452ed47f3aa6394e23b90037c241a`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-d4d0e2a https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575
git hash-object -t tree verify/tree.raw       # d93d081406eb2f1fcb7769269cc16512da291616
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree d93d081406eb2f1fcb7769269cc16512da291616 contracts   # ... tree 77ccd4f0bbc452ed47f3aa6394e23b90037c241a  contracts
git rev-parse HEAD:contracts              # 77ccd4f0bbc452ed47f3aa6394e23b90037c241a
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
