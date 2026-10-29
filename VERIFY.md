# Verifying audit-72c65de

The tag `audit-72c65de` publishes the contracts at commit `72c65defe75d97f781596ee3fd74ce7c1f6fd729` of our private repository `metric-core`.

No report names this commit itself. It is the `lib/metric-core` dependency of periphery commit `cc8fef9`, the Zellic re-audit's periphery starting point (`OMM Reaudit - Zellic Audit Report.pdf`, p. 10: "Only changes between cc8fef9...9b69f75"), published as tag [`audit-cc8fef9`](https://github.com/Metricxyz/periphery-contracts/tree/audit-cc8fef9).

The public tag is a new commit without the private history, so its own hash is not `72c65de`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `72c65de…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `72c65defe75d97f781596ee3fd74ce7c1f6fd729`, the commit pinned as `lib/metric-core`.
2. `commit.raw` names root tree `c4393dbd4300201b8c51b7cf9389016c286a7c0c`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `30585c3ce8632be5e8be64b66853c945234b22e1`.
4. In the public tag, `contracts/` must hash to the same `30585c3ce8632be5e8be64b66853c945234b22e1`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-72c65de https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 72c65defe75d97f781596ee3fd74ce7c1f6fd729
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 72c65defe75d97f781596ee3fd74ce7c1f6fd729
git hash-object -t tree verify/tree.raw       # c4393dbd4300201b8c51b7cf9389016c286a7c0c
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree c4393dbd4300201b8c51b7cf9389016c286a7c0c contracts   # ... tree 30585c3ce8632be5e8be64b66853c945234b22e1  contracts
git rev-parse HEAD:contracts              # 30585c3ce8632be5e8be64b66853c945234b22e1
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
