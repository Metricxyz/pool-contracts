# Verifying audit-33d0a34

The tag `audit-33d0a34` publishes the contracts at commit `33d0a3431fb711cfb84052d8380a09be69beef01` of our private repository `metric-core`. That commit is the version named in:

- **Zellic re-audit, September 2026** (`OMM Reaudit - Zellic Audit Report.pdf`, p. 10: "Only changes between 33d0a34...4410fec"). The re-audit reviewed the changes from this commit to `4410fec`, published as tag [`audit-4410fec`](https://github.com/Metricxyz/pool-contracts/tree/audit-4410fec).

The public tag is a new commit without the private history, so its own hash is not `33d0a34`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `33d0a34…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `33d0a3431fb711cfb84052d8380a09be69beef01`, the hash in the reports.
2. `commit.raw` names root tree `bec28ec53bb23e6f9daaae54fc0623e4437f9975`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `6f035fef61d3e6a154206c152a94f45a5bee4cbe`.
4. In the public tag, `contracts/` must hash to the same `6f035fef61d3e6a154206c152a94f45a5bee4cbe`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-33d0a34 https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 33d0a3431fb711cfb84052d8380a09be69beef01
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 33d0a3431fb711cfb84052d8380a09be69beef01
git hash-object -t tree verify/tree.raw       # bec28ec53bb23e6f9daaae54fc0623e4437f9975
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree bec28ec53bb23e6f9daaae54fc0623e4437f9975 contracts   # ... tree 6f035fef61d3e6a154206c152a94f45a5bee4cbe  contracts
git rev-parse HEAD:contracts              # 6f035fef61d3e6a154206c152a94f45a5bee4cbe
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Metricxyz/metric-core` and `github.com/Metric-OMM/metric-core`, the private repository. It is not public.
