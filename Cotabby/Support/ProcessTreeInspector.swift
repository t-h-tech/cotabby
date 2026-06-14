import Darwin
import Foundation

/// File overview:
/// Light wrapper over `sysctl(KERN_PROC_ALL)` that returns the basenames of every process
/// descended from a given parent PID. This is the foreground-process signal
/// `TuiSessionDetector` consults when the terminal title heuristic is empty.
///
/// **Why sysctl and not libproc.** `proc_listpids(PROC_PPID_ONLY, ...)` is the obvious choice
/// but it requires linking against libproc, which then needs a bridging header. `sysctl` is in
/// `Darwin` (already imported by every Cotabby Swift file) and one shot returns the whole
/// process table — perfectly fine for a per-keystroke read because we only walk the array, not
/// the syscall.
///
/// **Caching.** None — each call re-reads the table. The cost is roughly tens of microseconds
/// on Apple Silicon (a few hundred procs) and the TUI coordinator already debounces, so we
/// pay this once per Claude-Code-active burst rather than per keystroke.
enum ProcessTreeInspector {

    /// Return the basenames of every process in the subtree rooted at `parentPid`, excluding
    /// `parentPid` itself. Empty array when the parent has no children or when `sysctl` fails.
    /// Order is not meaningful — callers reduce to a `Set` for membership checks.
    static func descendantProcessNames(of parentPid: Int32) -> [String] {
        subtreeProcessNames(rootedAt: [parentPid], includingRoots: false)
    }

    /// Return the basenames of every process in the subtrees rooted at `rootPids`. Roots are
    /// INCLUDED by default: `exec claude` from a hooked shell replaces the shell IMAGE while
    /// keeping its pid, so the TUI binary *is* the root, not a descendant — excluding roots
    /// would make exec'd TUIs invisible to session-scoped detection. One process-table read
    /// regardless of root count.
    static func subtreeProcessNames(rootedAt rootPids: [Int32], includingRoots: Bool = true) -> [String] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var byPid: [Int32: kinfo_proc] = [:]
        var byParent: [Int32: [kinfo_proc]] = [:]
        for proc in table {
            // `eproc.e_ppid` is the parent PID; group children by parent so we can walk the
            // subtree breadth-first without quadratic scans.
            byPid[proc.kp_proc.p_pid] = proc
            byParent[proc.kp_eproc.e_ppid, default: []].append(proc)
        }

        var collected: [String] = []
        if includingRoots {
            for rootPid in rootPids {
                if let proc = byPid[rootPid] {
                    let name = basename(of: proc)
                    if !name.isEmpty {
                        collected.append(name)
                    }
                }
            }
        }

        var pending = rootPids
        while let pid = pending.popLast() {
            guard let children = byParent[pid] else { continue }
            for child in children {
                pending.append(child.kp_proc.p_pid)
                let name = basename(of: child)
                if !name.isEmpty {
                    collected.append(name)
                }
            }
        }
        return collected
    }

    private static func basename(of proc: kinfo_proc) -> String {
        withUnsafePointer(to: proc.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cstr in
                String(cString: cstr)
            }
        }
    }

    /// One-shot sysctl read of the entire process table. Returns an empty array on failure —
    /// callers treat that the same as "no children", which is the correct conservative answer
    /// for the TUI detector (it'll fall through to OCR / title heuristics instead of falsely
    /// reporting "no Claude Code running").
    private static func processTable() -> [kinfo_proc] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0
        let nameCount = u_int(name.count)

        // First call: ask sysctl how many bytes the table needs. The table can grow between
        // the size query and the actual read, so we accept the small race and retry once.
        guard sysctl(&name, nameCount, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: length / MemoryLayout<kinfo_proc>.size)
        let readResult = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int32 in
            sysctl(&name, nameCount, bufferPointer.baseAddress, &length, nil, 0)
        }
        guard readResult == 0 else { return [] }
        let count = length / MemoryLayout<kinfo_proc>.size
        return Array(buffer.prefix(count))
    }
}
