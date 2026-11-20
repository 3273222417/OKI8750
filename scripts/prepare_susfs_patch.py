#!/usr/bin/env python3
"""Select the matching vendor VMA hunk in the current SUSFS patch."""

import re
import sys
from pathlib import Path


def prepare(patch, task_mmu):
    sections = re.split(r"(?=^diff --git )", patch, flags=re.M)
    indexes = [i for i, s in enumerate(sections) if s.startswith("diff --git a/fs/proc/task_mmu.c ")]
    if len(indexes) != 1:
        raise ValueError("expected one fs/proc/task_mmu.c section")
    index = indexes[0]
    hunks = re.split(r"(?=^@@ )", sections[index], flags=re.M)

    # The upstream patch contains both vendor layouts of the same Case 4
    # branch. Only apply the variant whose unmodified lines are present.
    case4 = [h for h in hunks if h.startswith("@@ ") and "/* Case 4 above */" in h]
    if len(case4) != 2:
        raise ValueError("expected the two pinned smaps_rollup alternatives")
    matches = [
        h for h in case4
        if "".join(s[1:] for s in h.splitlines(keepends=True)[1:] if s.startswith((" ", "-"))) in task_mmu
    ]
    if len(matches) != 1:
        raise ValueError("kernel does not match exactly one smaps_rollup alternative")
    hunks = [h for h in hunks if h not in case4 or h == matches[0]]

    # Mirror the vendor's existing VMA bounds calculation instead of testing
    # whether its function name is a preprocessor macro. Guard lock cleanup
    # on vendor layouts that return early before printing a VMA.
    start = task_mmu.index("\nshow_map_vma(struct seq_file")
    vendor = re.search(
        r"^\tstart = vma->vm_start;\n(?P<bounds>.*?)^\tshow_vma_header_prefix\(",
        task_mmu[start:], re.M | re.S,
    )
    if not vendor:
        raise ValueError("could not locate the vendor's VMA bounds calculation")
    bounds = vendor["bounds"].strip("\n")
    if not bounds.startswith("\tend = ") or "\n}" in bounds:
        raise ValueError("unrecognized vendor VMA bounds calculation")
    lines = []
    for line in bounds.splitlines():
        if line.strip() == "return;":
            indent = line[:len(line) - len(line.lstrip())]
            lines += [indent + "{", indent + "\tsrcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);",
                      indent + "\treturn;", indent + "}"]
        else:
            lines.append(line)
    old = re.compile(r"^\+\t+end = VMA_PAD_START\(vma\);\n\+#ifdef __fold_filemap_fixup_entry\n"
                     r"(?:^\+.*\n)*?^\+#endif\n", re.M)
    replaced = 0
    for i, hunk in enumerate(hunks):
        body, hits = old.subn(lambda _: "".join("+" + ("\t\t\t" if line else "") + line + "\n" for line in lines), hunk)
        if hits:
            new_count = sum(line.startswith((" ", "+")) for line in body.splitlines()[1:])
            hunks[i] = re.sub(r"^(@@ -\d+(?:,\d+)? \+\d+),\d+( @@)", rf"\g<1>,{new_count}\2", body, count=1)
        replaced += hits
    if replaced != 1:
        raise ValueError("unexpected VMA bounds hunk in pinned SUSFS patch")
    sections[index] = "".join(hunks)
    return "".join(sections)


if __name__ == "__main__":
    source, task_mmu, output = (Path(p) for p in sys.argv[1:])
    try:
        patched = prepare(source.read_text(encoding="utf-8"), task_mmu.read_text(encoding="utf-8"))
        output.write_text(patched, encoding="utf-8", newline="\n")
    except (OSError, ValueError) as exc:
        sys.exit(f"SUSFS vendor patch preparation failed: {exc}")
