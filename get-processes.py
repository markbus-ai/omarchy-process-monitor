#!/usr/bin/python3
"""
Get real aggregated RAM usage per process tree.

This script reads /proc to build a process tree and sums up RSS
(memory) for ALL descendants of each root process. This gives you
the REAL memory usage - not just the parent's, but the total of
all its children, grandchildren, etc.

Output: JSON with process list sorted by real aggregated RAM.
"""

import os
import sys
import json
import pwd

def get_process_info(pid):
    """Read process info from /proc/[pid]/stat and /proc/[pid]/status."""
    try:
        # Read stat file for CPU info
        with open(f"/proc/{pid}/stat", "r") as f:
            stat = f.read().split(")")
            if len(stat) < 2:
                return None
            fields = stat[1].split()
            # fields[11] = utime, fields[12] = stime
            utime = int(fields[11]) if len(fields) > 11 else 0
            stime = int(fields[12]) if len(fields) > 12 else 0
            
        # Read status file for memory info
        rss_pages = 0
        num_threads = 1
        with open(f"/proc/{pid}/status", "r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    rss_pages = int(line.split()[1])  # in kB
                elif line.startswith("Threads:"):
                    num_threads = int(line.split()[1])

        # starttime (jiffies since boot): stable age/identity for grouping
        starttime = "0"
        try:
            sfields = stat[1].split()
            if len(sfields) > 19:
                starttime = sfields[19]
        except Exception:
            pass
        
        # Read cmdline
        cmdline = ""
        try:
            with open(f"/proc/{pid}/cmdline", "r") as f:
                cmdline = f.read().replace("\x00", " ").strip()
        except:
            pass
        
        # Get process name from stat (clean up the format)
        name = stat[0].strip()
        # Remove leading PID and parentheses: "12345 (bash" -> "bash"
        if "(" in name and ")" not in name:
            name = name.split("(", 1)[1] if "(" in name else name
        elif name.startswith("("):
            name = name[1:]
        
        # Get username
        try:
            uid = os.stat(f"/proc/{pid}").st_uid
            username = pwd.getpwuid(uid).pw_name
        except:
            username = "unknown"
        
        return {
            "pid": pid,
            "name": name,
            "cmdline": cmdline[:200] if cmdline else name,
            "rss_kb": rss_pages,
            "cpu_ticks": utime + stime,
            "threads": num_threads,
            "username": username,
            "starttime": starttime
        }
    except (FileNotFoundError, PermissionError, IndexError, ValueError):
        return None

def get_ppid(pid):
    """Get parent PID from /proc/[pid]/stat.

    After "(comm)": fields[0]=state, fields[1]=ppid, fields[2]=pgrp...
    (ppid is the SECOND token, not the fourth — fields[3] is the session id
    and grouping by it splits real trees apart.)
    """
    try:
        with open(f"/proc/{pid}/stat", "r") as f:
            stat = f.read().split(")")
            if len(stat) < 2:
                return 1
            fields = stat[1].split()
            return int(fields[1]) if len(fields) > 1 else 1
    except:
        return 1

def build_process_forest():
    """Build a forest of process trees from /proc.

    Returns (processes, children, ppids):
      processes: pid -> info dict
      children: ppid -> [child pids]
      ppids: pid -> parent pid
    """
    processes = {}
    children = {}  # ppid -> [pids]
    ppids = {}  # pid -> ppid

    # Collect all PIDs
    for entry in os.listdir("/proc"):
        try:
            pid = int(entry)
            if pid <= 0:
                continue
            info = get_process_info(pid)
            if info:
                processes[pid] = info
                ppid = get_ppid(pid)
                ppids[pid] = ppid
                if ppid not in children:
                    children[ppid] = []
                children[ppid].append(pid)
        except (ValueError, NotADirectoryError):
            continue

    return processes, children, ppids

def compute_subtree_rss(pid, children, processes, visited=None):
    """Recursively compute total RSS for a process and all its descendants."""
    if visited is None:
        visited = set()
    if pid in visited:
        return 0
    visited.add(pid)
    total = processes.get(pid, {}).get("rss_kb", 0)
    for child_pid in children.get(pid, []):
        total += compute_subtree_rss(child_pid, children, processes, visited)
    return total

# Never shown as rows: init, kthreadd and the systemd managers aggregate
# the whole system; their qualifying children already promote to top level.
HIDDEN_COMMS = {"systemd", "kthreadd"}


def is_display_root(pid, processes, ppids):
    """A process gets its own row when it starts a new 'app unit'.

    Same-name parent->child chains (browser + renderers, service + workers)
    collapse into one row; differently-named children split off.
    Managers (pid 0/1/2, systemd, kthreadd) never get rows.
    """
    if pid in (0, 1, 2):
        return False
    info = processes.get(pid)
    if not info:
        return False
    if info["name"] in HIDDEN_COMMS:
        return False
    ppid = ppids.get(pid, 1)
    if ppid in (0, 1, 2):
        return True  # parent hidden -> promote
    parent = processes.get(ppid)
    if parent is None:
        return True  # orphan -> own row
    if ppid == pid:
        return True
    if parent["name"] in HIDDEN_COMMS:
        return True  # parent hidden -> promote
    return parent["name"] != info["name"]


def subtree_members(pid, children, processes):
    """All pids in pid's subtree (inclusive), cycle-safe."""
    seen = set()
    stack = [pid]
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        for c in children.get(x, []):
            if c in processes:
                stack.append(c)
    return seen


def find_root_processes(processes, children, ppids=None):
    """Display roots (see is_display_root). ppids map optional (rebuilt if missing)."""
    if ppids is None:
        ppids = {}
        for pid in processes:
            ppids[pid] = get_ppid(pid)
    return [pid for pid in processes if is_display_root(pid, processes, ppids)]


def subtree_total(pid, processes, children):
    members = subtree_members(pid, children, processes)
    return sum(processes[m]["rss_kb"] for m in members)


def resolve_chain(pid, processes, children):
    """Collapse single-child wrapper chains down to the heavy node.

    foot(24M) -> zsh(11M) -> opencode(970M) becomes one "opencode" row.
    Only collapses through negligible wrappers (own < 10% of subtree);
    multi-child nodes always stop the descent. Cycle-safe.
    """
    seen = set()
    while True:
        if pid in seen:
            break
        seen.add(pid)
        kids = [c for c in children.get(pid, []) if c in processes and c != pid]
        if len(kids) != 1:
            break
        total = subtree_total(pid, processes, children)
        if total <= 0:
            break
        if processes[pid]["rss_kb"] > 0.10 * total:
            break
        pid = kids[0]
    return pid


def resolve_dedup(pids, processes, children, claimed):
    """Resolve wrapper chains, dropping nodes already claimed by bigger rows."""
    out = []
    for pid in pids:
        if pid in claimed:
            continue
        final = resolve_chain(pid, processes, children)
        if final in claimed:
            continue
        claimed.add(final)
        out.append(final)
    return out


# Interpreters: same binary, different programs -> split by script argument.
INTERPRETERS = {
    "python", "python3", "python2", "node", "deno", "bun", "ruby",
    "perl", "php", "bash", "sh", "zsh", "fish", "dash", "lua", "Rscript",
    "java", "awk", "gawk",
}


def exe_of(pid):
    """Kernel-resolved binary path, or None."""
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except Exception:
        return None


def group_key(pid, processes):
    """App identity: same binary (+script for interpreters) + same user.

    One Firefox/zen binary with 20 --type helpers -> ONE row.
    Two `python3 a.py` vs `python3 b.py` -> separate rows.
    """
    info = processes.get(pid)
    if not info:
        return ("?", "", "")
    exe = exe_of(pid)
    if exe is None:
        return ("comm:" + info["name"], "", info["username"])
    base = exe.rsplit("/", 1)[-1]
    script = ""
    if base in INTERPRETERS:
        parts = (info.get("cmdline") or "").split(" ")
        for tok in parts[1:]:
            if tok == "" or tok.startswith("-"):
                continue
            script = tok.rsplit("/", 1)[-1]
            break
    return (exe, script, info["username"])


def group_roots(roots, processes, children):
    """Merge display-roots of the same app into groups.

    Returns [{key, members(set), kroots:[pids], main:pid}].
    Groups sorted by total RSS desc.
    """
    groups = {}
    order = []
    for r in roots:
        key = group_key(r, processes)
        if key not in groups:
            groups[key] = {"key": key, "members": set(), "kroots": []}
            order.append(key)
        g = groups[key]
        g["kroots"].append(r)
        for m in subtree_members(r, children, processes):
            g["members"].add(m)
    ranked = []
    for key in order:
        g = groups[key]
        total = sum(processes[m]["rss_kb"] for m in g["members"] if m in processes)
        ranked.append((total, key))
    ranked.sort(reverse=True)
    return [groups[key] for _, key in ranked]

def child_entry(cpid, processes, children):
    """Detail record for one child: subtree totals + counts."""
    cinfo = processes[cpid]
    members = subtree_members(cpid, children, processes)
    grandkids = [g for g in children.get(cpid, []) if g in processes and g != cpid]
    return {
        "pid": cpid,
        "name": cinfo["name"],
        "cmdline": cinfo["cmdline"],
        "rss_kb": sum(processes[m]["rss_kb"] for m in members),
        "own_rss_kb": cinfo["rss_kb"],
        "username": cinfo["username"],
        "child_count": len(grandkids),
        "descendants": len(members) - 1,
    }


def aggregate_processes(processes, children, ppids=None):
    """Aggregate RAM per display-root tree, collapsing wrapper chains.

    Biggest subtrees claim their members first, so overlapping chains
    (foot->zsh->opencode) produce ONE row instead of three.
    """
    roots = find_root_processes(processes, children, ppids)
    roots.sort(key=lambda r: subtree_total(r, processes, children), reverse=True)

    claimed = set()
    final_roots = resolve_dedup(roots, processes, children, claimed)
    groups = group_roots(final_roots, processes, children)
    aggregated = []

    for g in groups:
        members = g["members"]
        claimed |= members

        def age_key(p):
            try:
                return (int(processes[p].get("starttime") or 0), p)
            except Exception:
                return (0, p)

        main_pid = min((m for m in members if m in processes), key=age_key)
        root_info = processes[main_pid]

        # Merged direct children across all group roots (for expansion)
        kid_seen = set()
        kid_pids = []
        for kr in g["kroots"]:
            for c in children.get(kr, []):
                if c in processes and c != kr and c not in kid_seen:
                    kid_seen.add(c)
                    kid_pids.append(c)
        kid_finals = resolve_dedup(kid_pids, processes, children, set())
        child_details = [child_entry(c, processes, children) for c in kid_finals]
        child_details.sort(key=lambda x: x["rss_kb"], reverse=True)

        aggregated.append({
            "pid": main_pid,
            "name": root_info["name"],
            "cmdline": root_info["cmdline"],
            "rss_kb": sum(processes[m]["rss_kb"] for m in members if m in processes),
            "own_rss_kb": root_info["rss_kb"],
            "descendants": max(0, len(members) - 1),
            "total_threads": sum(processes[m].get("threads", 0) for m in members if m in processes),
            "username": root_info["username"],
            "cpu_ticks": sum(processes[m].get("cpu_ticks", 0) for m in members if m in processes),
            "kroots": g["kroots"],
            "top_children": child_details[:8]
        })

    # Sort by real aggregated RSS (descending)
    aggregated.sort(key=lambda x: x["rss_kb"], reverse=True)
    return aggregated

def get_total_memory():
    """Get total system memory in kB."""
    with open("/proc/meminfo", "r") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                return int(line.split()[1])
    return 0

def get_available_memory():
    """Get available memory in kB."""
    with open("/proc/meminfo", "r") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1])
    return 0

def children_of(pid, processes, children, limit=12):
    """Direct children of one pid with subtree totals (for lazy drill-down)."""
    kids = [c for c in children.get(pid, []) if c in processes and c != pid]
    finals = resolve_dedup(kids, processes, children, set())
    result = [child_entry(c, processes, children) for c in finals]
    result.sort(key=lambda x: x["rss_kb"], reverse=True)
    return result[:limit]


def read_identity(pid):
    """Fresh (comm, starttime) for a pid, or None if unreadable.

    starttime is jiffies since boot: PID-reuse-proof identity together
    with comm. Read live from /proc at call time (never from cache).
    """
    try:
        with open(f"/proc/{pid}/stat", "r") as f:
            stat = f.read().split(")")
            if len(stat) < 2:
                return None
            comm = stat[0].split("(", 1)[1] if "(" in stat[0] else stat[0].strip()
            fields = stat[1].split()
            if len(fields) <= 19:
                return None
            return {"comm": comm, "starttime": fields[19]}
    except Exception:
        return None


def tree_pids(target, processes, children, cap=2000):
    """Identity snapshot [{pid, comm, starttime}] of a tree for later verification."""
    if target <= 2:
        return []
    out = []
    for p in sorted(subtree_members(target, children, processes)):
        if p <= 2:
            continue
        ident = read_identity(p)
        if ident is None:
            continue
        out.append({"pid": p, "comm": ident["comm"], "starttime": ident["starttime"]})
        if len(out) >= cap:
            break
    return out


def kill_checked(signum, snapshot):
    """Signal only pids whose live identity still matches the snapshot.

    Guards against PID reuse between listing and killing. Returns report.
    """
    killed = 0
    skipped = []
    failed = []
    for entry in snapshot:
        try:
            pid = int(entry["pid"])
        except Exception:
            continue
        if pid <= 2:
            skipped.append(pid)
            continue
        live = read_identity(pid)
        if live is None:
            skipped.append(pid)
            continue
        if live["comm"] != entry.get("comm") or str(live["starttime"]) != str(entry.get("starttime")):
            skipped.append(pid)
            continue
        try:
            os.kill(pid, signum)
            killed += 1
        except Exception:
            failed.append(pid)
    return {"signal": signum, "killed": killed, "skipped": skipped, "failed": failed}


def main():
    # Lazy mode: children of a single pid (for expanding tree nodes)
    if len(sys.argv) > 2 and sys.argv[1] == "children":
        try:
            target = int(sys.argv[2])
        except ValueError:
            print("[]")
            return
        processes, children, _ppids = build_process_forest()
        print(json.dumps(children_of(target, processes, children)))
        return

    # Snapshot mode: identity list of one or more trees (comma-separated
    # pids, for merged app groups) for later verified killing
    if len(sys.argv) > 2 and sys.argv[1] == "tree-pids":
        try:
            targets = [int(x) for x in sys.argv[2].split(",") if x.strip() != ""]
        except ValueError:
            print("[]")
            return
        if not targets:
            print("[]")
            return
        processes, children, _ppids = build_process_forest()
        seen = set()
        out = []
        for target in targets:
            for e in tree_pids(target, processes, children):
                if e["pid"] not in seen:
                    seen.add(e["pid"])
                    out.append(e)
        # Include each target root itself
        for target in targets:
            if target in processes and target > 2 and target not in seen:
                ident = read_identity(target)
                if ident is not None:
                    seen.add(target)
                    out.append({"pid": target, "comm": ident["comm"],
                                "starttime": ident["starttime"]})
        print(json.dumps(out))
        return

    # Verified-kill mode: signal only pids matching the base64 snapshot
    if len(sys.argv) > 3 and sys.argv[1] == "killchecked":
        try:
            signum = int(sys.argv[2])
            import base64
            snapshot = json.loads(base64.b64decode(sys.argv[3]).decode("utf-8"))
        except Exception:
            print(json.dumps({"error": "bad-args"}))
            return
        if signum not in (9, 15) or not isinstance(snapshot, list):
            print(json.dumps({"error": "bad-signal"}))
            return
        print(json.dumps(kill_checked(signum, snapshot)))
        return

    total_mem = get_total_memory()
    available_mem = get_available_memory()
    used_mem = total_mem - available_mem

    processes, children, ppids = build_process_forest()
    aggregated = aggregate_processes(processes, children, ppids)
    
    # Get top N by count
    top_count = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    top_processes = aggregated[:top_count]
    
    try:
        current_user = pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        current_user = ""

    result = {
        "total_mem_kb": total_mem,
        "used_mem_kb": used_mem,
        "available_mem_kb": available_mem,
        "usage_percent": round((used_mem / total_mem) * 100, 1) if total_mem > 0 else 0,
        "total_processes": len(processes),
        "current_user": current_user,
        "processes": top_processes
    }
    
    print(json.dumps(result))

if __name__ == "__main__":
    main()
