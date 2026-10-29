# Verifying audit-6aa6c3b

The tag `audit-6aa6c3b` publishes the contracts at commit `6aa6c3b489b84b8b1c50dc6a4967184df17aa395` of our private repository `metric-core`. That commit is the version named in:

- **Zellic audit, June 2026** (`Metric OMM - Zellic Audit Report.pdf`, p. 9: "Version 6aa6c3b489…")
- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 2: "AuditedCommit: 6aa6c3b489…")

The public tag is a new commit without the private history, so its own hash is not `6aa6c3b`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `6aa6c3b…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `6aa6c3b489b84b8b1c50dc6a4967184df17aa395`, the hash in the reports.
2. `commit.raw` names root tree `43fb90d5a7df2fa7d83112120846b114eff68d4d`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `2f9590d9f9929afeec08e21840bc42dc2abc31cc`.
4. In the public tag, `contracts/` must hash to the same `2f9590d9f9929afeec08e21840bc42dc2abc31cc`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-6aa6c3b https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 6aa6c3b489b84b8b1c50dc6a4967184df17aa395
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 6aa6c3b489b84b8b1c50dc6a4967184df17aa395
git hash-object -t tree verify/tree.raw       # 43fb90d5a7df2fa7d83112120846b114eff68d4d
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 43fb90d5a7df2fa7d83112120846b114eff68d4d contracts   # ... tree 2f9590d9f9929afeec08e21840bc42dc2abc31cc  contracts
git rev-parse HEAD:contracts              # 2f9590d9f9929afeec08e21840bc42dc2abc31cc
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
