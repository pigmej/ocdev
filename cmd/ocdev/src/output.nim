## Output helper functions for consistent messaging
import std/strformat

proc info*(msg: string) =
  ## Print info message to stderr with [INFO] prefix
  stderr.writeLine(fmt"[INFO] {msg}")

proc warn*(msg: string) =
  ## Print warning message to stderr with [WARN] prefix
  stderr.writeLine(fmt"[WARN] {msg}")

proc error*(msg: string) =
  ## Print error message to stderr with [ERROR] prefix
  stderr.writeLine(fmt"[ERROR] {msg}")

proc success*(msg: string) =
  ## Print success message to stdout with [OK] prefix
  echo fmt"[OK] {msg}"
