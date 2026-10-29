#!/usr/bin/env python3
"""Check that the public audit-7b9ab56 tag holds the audited contracts.

Usage: python verify.py <path to a clone of Metricxyz/pool-contracts at tag audit-7b9ab56>

Needs only Python 3 and git. commit.raw and tree.raw must sit next to this script.
"""
import hashlib, os, re, subprocess, sys

AUDITED_COMMIT = "7b9ab567631a234ba5d467c646a1da9cbfb25479"  # as printed in the audit reports
HERE = os.path.dirname(os.path.abspath(__file__))


def git_hash(kind, data):
    return hashlib.sha1(kind + b" " + str(len(data)).encode() + b"\0" + data).hexdigest()


def tree_entries(data):
    i = 0
    while i < len(data):
        sp = data.index(b" ", i)
        nul = data.index(b"\0", sp)
        yield data[sp + 1:nul].decode(), data[nul + 1:nul + 21].hex()
        i = nul + 21


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    commit = open(os.path.join(HERE, "commit.raw"), "rb").read()
    tree = open(os.path.join(HERE, "tree.raw"), "rb").read()

    commit_hash = git_hash(b"commit", commit)
    print("1. sha1 of commit.raw          ", commit_hash)
    assert commit_hash == AUDITED_COMMIT, "commit.raw is not the audited commit"

    root = re.search(rb"^tree ([0-9a-f]{40})$", commit, re.M).group(1).decode()
    tree_hash = git_hash(b"tree", tree)
    print("2. root tree named by commit   ", root)
    print("   sha1 of tree.raw            ", tree_hash)
    assert tree_hash == root, "tree.raw is not the audited commit's root tree"

    audited = dict(tree_entries(tree))["contracts"]
    print("3. contracts/ in audited commit", audited)

    public = subprocess.check_output(["git", "-C", sys.argv[1], "rev-parse", "HEAD:contracts"], text=True).strip()
    print("4. contracts/ in public clone  ", public)
    assert public == audited, "public contracts/ differs from the audited one"

    print("\nOK: contracts/ at this tag is identical to contracts/ in audited commit", AUDITED_COMMIT)


if __name__ == "__main__":
    main()
