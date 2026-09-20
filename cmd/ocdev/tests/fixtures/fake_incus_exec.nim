## Deliberately closed fake backend: no shell and no live Incus fallthrough.
import std/[os, json, strutils, posix]

proc exitWithStatus(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

var received {.volatile.}: cint
proc onSignal(sig: cint) {.noconv.} = received = sig

proc payload(): string =
  for i in 0 ..< 100000: result.add(char(i mod 256))

proc reversedBytes(value: string): string =
  for i in countdown(value.high, 0): result.add(value[i])

proc main() =
  let args = commandLineParams()
  # Used by the test's real OS pipe, not by the fake backend dispatch.
  if args == @["produce-stdin"]:
    stdout.write(payload())
    return
  let home = getEnv("HOME")
  let settings = parseJson(readFile(home / "fixture.json"))
  proc barrier(kind: string) =
    signal(SIGINT, onSignal)
    signal(SIGTERM, onSignal)
    writeFile(home / "incus.pid", $getCurrentProcessId())
    writeFile(home / (kind & "-ready"), "ready")
    for attempt in 0 ..< 3000:
      if received != 0:
        writeFile(home / "signal", $received)
        if not settings{"ignoreSignals"}.getBool: exitWithStatus(128 + received)
      if fileExists(home / "release"): return
      sleep(5)
    quit(98)
  let log = open(home / "calls", fmAppend)
  log.writeLine($(%args))
  log.close()
  if args == @["list", "--format=json", "^ocdev-demo$"]:
    if settings{"blockList"}.getBool: barrier("list")
    case settings{"query"}.getStr
    of "failure":
      stdout.write("backend-private-output")
      stderr.write("backend-private-error")
      quit(9)
    of "malformed": stdout.write("not-json")
    of "wrong-shape": stdout.write("{}")
    of "missing": stdout.write("[]")
    else:
      echo %*[{"name": "ocdev-demo", "status": settings{"status"}.getStr("Running"),
        "config": {"volatile.uuid": settings{"uuid"}.getStr("demo-uuid")}}]
    return
  if args.len < 3 or args[0 .. 1] != @["exec", "ocdev-demo"]:
    quit("Unsupported fake Incus invocation: " & $args, 99)
  let separator = args.find("--")
  if separator < 0 or separator == args.high: quit("Missing guest command", 99)
  writeFile(home / "exec-argv", $(%args))
  let wrapper = args[separator + 1 .. ^1]
  if wrapper.len < 5 or wrapper[0 .. 3] != @["runuser", "-u", "dev", "--"]:
    quit("Expected dev user without shell interpretation", 99)
  let guest = wrapper[4 .. ^1]
  case guest[0]
  of "literal": discard
  of "streams":
    stdout.write(payload())
    stderr.write(payload().reversedBytes())
  of "stdin": stdout.write(stdin.readAll())
  of "exit": exitWithStatus(cint(parseInt(guest[1])))
  of "signal":
    let sig = cint(parseInt(guest[1]))
    signal(sig, SIG_DFL)
    discard kill(Pid(getCurrentProcessId()), sig)
    quit(99)
  of "block": barrier("exec")
  else: quit("Unsupported fake guest command", 99)

main()
