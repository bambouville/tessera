import Foundation

/// Bounded, route-scoped process inventory for fresh terminal input checks.
public enum AgentProcessSnapshotCommand {
    public static let outputLineLimit = 64
    public static let outputColumnLimit = 1_000
    public static let maximumExpectedOutputBytes = outputLineLimit * (outputColumnLimit + 1)

    public static func makeCommand(rootPID: Int?, expectedPID: Int? = nil) -> String {
        let rootAssignment: String
        if let rootPID, rootPID > 0 {
            rootAssignment = "r=\(rootPID); "
        } else {
            rootAssignment = "r=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' '); "
        }

        let expected = expectedPID.flatMap { $0 > 1 ? $0 : nil } ?? 0
        return rootAssignment
        + "u=$(id -un 2>/dev/null || whoami 2>/dev/null || printf ''); "
        + "{ "
        + "if [ -n \"$u\" ]; then "
        + "ps -ww -u \"$u\" -o pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -u \"$u\" -o pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -ww -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null; "
        + "else "
        + "ps -ww -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null; "
        + "fi; } | awk '$4 != \"?\" && $4 != \"??\" && $4 != \"-\" { print }' "
        + "| awk -v root=\"$r\" '"
        + "$1 ~ /^[0-9]+$/ { parent[$1]=$2; tty[$1]=$4; line[$1]=$0 } "
        + "function attached(t) { return t != \"?\" && t != \"??\" && t != \"-\" } "
        + "function inside(pid, depth) { "
        + "for (depth=0; pid != \"\" && pid != \"0\" && depth < 64; depth++) { "
        + "if (pid == root) return 1; pid = parent[pid] "
        + "} return 0 "
        + "} "
        // Keep the expected agent last so tail cannot discard its authority.
        // It must pass the same attached-TTY and ancestry checks as every row.
        + "END { expected=\(expected); for (pid in line) if (pid != expected && attached(tty[pid]) && root != \"\" && inside(pid)) print line[pid]; "
        + "if (expected in line && attached(tty[expected]) && root != \"\" && inside(expected)) print line[expected] }"
        + "' "
        + "| tail -n \(outputLineLimit) | cut -c 1-\(outputColumnLimit); exit 0"
    }

}
