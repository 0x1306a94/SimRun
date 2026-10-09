#!/bin/zsh
# capture.sh <pgrep -f pattern> <out.png> [window title] — screenshot that process's largest (or titled) window
P=$(pgrep -f "$1" | head -1); [ -z "$P" ] && { echo "no process"; exit 1; }
cat > /tmp/simrun_wid.swift <<'S'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let title: String? = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let l = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
let ws = l.filter { ($0["kCGWindowOwnerPID"] as? Int) == pid && ($0["kCGWindowLayer"] as? Int) == 0 && (title == nil || ($0["kCGWindowName"] as? String) == title) }
if let w = ws.max(by: { (($0["kCGWindowBounds"] as? [String: Any])?["Height"] as? Double ?? 0) < (($1["kCGWindowBounds"] as? [String: Any])?["Height"] as? Double ?? 0) }) { print(w["kCGWindowNumber"]!) }
S
WID=$(swift /tmp/simrun_wid.swift $P ${3:+"$3"} 2>/dev/null); [ -z "$WID" ] && { echo "no window"; exit 1; }
screencapture -x -o -l$WID "$2" && echo "captured $2"
