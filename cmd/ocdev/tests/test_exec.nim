## Offline black-box exec contract. Only the compiled fake is on PATH.
import std/[os, json, strutils, unittest, posix]
import test_support
import ../src/recipes

disableParamFiltering()
doAssert paramCount() == 2, "Usage: test_exec OCDEV FAKE_INCUS"
let binary = absolutePath(paramStr(1))
let fakeBinary = absolutePath(paramStr(2))

proc settings(s: Sandbox; value: JsonNode) = writeJson(s.home / "fixture.json", value)
proc lockPath(s: Sandbox): string = s.home / ".ocdev/environments/demo.lock"
proc waitFor(path: string): bool =
  for attempt in 0 ..< 1000:
    if fileExists(path): return true
    sleep(5)
proc payload(): string =
  for i in 0 ..< 100000: result.add(char(i mod 256))
proc managed(s: Sandbox) =
  let path = s.home / "recipe.json"
  writeJson(path, %*{"schemaVersion": 1, "id": "demo", "name": "Demo",
    "source": {"snapshot": "base/ready"}, "tasks": {}})
  let recipe = loadRecipe(path)
  createDir(s.home / ".ocdev/environments")
  writeJson(s.home / ".ocdev/environments/demo.json", %*{
    "name": "demo", "uuid": "demo-uuid", "recipe": recipe, "digest": recipeDigest(recipe)})
proc rejected(s: Sandbox; args: seq[string]) =
  let r = s.run(binary, args)
  checkpoint($args & ": " & r.error)
  check r.code != 0
  check r.output == ""
  check r.error.len > 0
  check not fileExists(s.home / "exec-argv")
proc noHistory(s: Sandbox) =
  for directory in [s.home / ".ocdev/runs", s.home / ".ocdev/logs"]:
    if dirExists(directory):
      for path in walkDirRec(directory):
        checkpoint("Unexpected exec history/log file: " & path)
        check false
proc lockAvailable(s: Sandbox) =
  let fd = acquireLock(s.lockPath)
  releaseLock(fd)

suite "Direct exec CLI":
  setup:
    let s = newSandbox("ocdev-exec-", fakeBinary)
    s.env["PATH"] = s.home
    s.settings(newJObject())
  teardown:
    s.close()

  test "direct literal argv, dev identity, default and explicit cwd":
    let guest = @["literal", "two words", "$(touch forbidden)", "; echo no", "*", "", "--help", "--json"]
    for cwd in ["/home/dev", "/workspace/a directory"]:
      let options = if cwd == "/home/dev": @[] else: @["--cwd", cwd]
      let r = s.run(binary, @["exec", "demo"] & options & @["--"] & guest)
      check r.code == 0
      check r.output == ""
      check r.error == ""
      let args = readJson(s.home / "exec-argv").getElems
      var argv: seq[string]
      for item in args: argv.add(item.getStr)
      let separator = argv.find("--")
      require separator >= 0
      check argv[separator + 1 .. ^1] == @["runuser", "-u", "dev", "--"] & guest
      let optionsSeen = argv[2 ..< separator]
      check "--cwd" in optionsSeen
      check optionsSeen[optionsSeen.find("--cwd") + 1] == cwd
      check "--mode=non-interactive" in optionsSeen or
        ("--mode" in optionsSeen and optionsSeen[optionsSeen.find("--mode") + 1] == "non-interactive")
      check not fileExists(s.home / "forbidden")
    let equalsCwd = s.run(binary, @["exec", "--cwd=/tmp", "demo", "--", "literal"])
    check equalsCwd.code == 0
    check equalsCwd.output == ""
    check equalsCwd.error == ""
    s.noHistory()

  test "large separate binary streams are byte exact":
    let r = s.run(binary, @["exec", "demo", "--", "streams"])
    var reverse = ""
    let data = payload()
    for i in countdown(data.high, 0): reverse.add(data[i])
    check r.code == 0
    check r.output == data
    check r.error == reverse
    s.noHistory()

  test "stdin is a real pipe and binary bytes survive":
    let script = "\"$1\" produce-stdin | \"$2\" exec demo -- stdin"
    let r = s.run("/bin/sh", @["-c", script, "exec-pipe", fakeBinary, binary])
    check r.code == 0
    check r.output == payload()
    check r.error == ""

  test "guest exit statuses are not wrapped":
    for code in [7, 127, 128, 130, 143, 255]:
      let r = s.run(binary, @["exec", "demo", "--", "exit", $code])
      check r.code == code
      check r.output == ""
      check r.error == ""
    s.noHistory()

  test "client signal exits preserve the conventional exit status":
    for sig in [SIGINT, SIGTERM]:
      let r = s.run(binary, @["exec", "demo", "--", "signal", $sig])
      check r.code == 128 + int(sig)
      check r.output == ""
      check r.error == ""

  test "syntax errors fail before invoking backend":
    for args in [@["exec"], @["exec", "demo"], @["exec", "demo", "--"],
        @["exec", "--", "literal"], @["exec", "../demo", "--", "literal"],
        @["exec", "", "demo", "--", "literal"],
        @["exec", "demo", "--cwd=", "--", "literal"],
        @["exec", "demo", "--cwd=/tmp", "--cwd=/home/dev", "--", "literal"],
        @["exec", "demo", "--cwd", "relative", "--", "literal"],
        @["exec", "demo", "--cwd", "--", "literal"],
        @["exec", "demo", "--surprise", "--", "literal"],
        @["exec", "demo", "--json", "--", "literal"],
        @["--json", "exec", "demo", "--", "literal"]]:
      s.rejected(args)
    check not fileExists(s.home / "calls")

  test "help routing and normalized command names":
    for command in ["exec", "eXEC", "e-xec"]:
      let r = s.run(binary, @[command, "--help"])
      check r.code == 0
      check "exec" in r.output.toLowerAscii
    s.rejected(@["ex", "demo", "--", "literal"])
    for command in ["export", "exp"]:
      let r = s.run(binary, @[command, "--help"])
      check r.code == 0
      check "export" in r.output.toLowerAscii
    check not fileExists(s.home / "calls")
    let r = s.run(binary, @["e-xEC", "demo", "--", "literal", "--help", "--json"])
    check r.code == 0
    check r.output == ""

  test "missing stopped malformed and failed backend queries":
    for value in [%*{"query": "missing"}, %*{"status": "Stopped"},
        %*{"query": "malformed"}, %*{"query": "wrong-shape"}, %*{"query": "failure"}]:
      s.settings(value)
      s.rejected(@["exec", "demo", "--", "literal"])
    s.noHistory()

  test "plain and recipe environments honor held locks":
    createDir(s.home / ".ocdev/environments")
    for recipe in [false, true]:
      if recipe: s.managed()
      let fd = acquireLock(s.lockPath)
      try: s.rejected(@["exec", "demo", "--", "literal"])
      finally: releaseLock(fd)
    s.noHistory()

  test "pinned recipe UUID and running guard":
    s.managed()
    for value in [%*{"uuid": "replacement-uuid"}, %*{"status": "Stopped"}]:
      s.settings(value)
      s.rejected(@["exec", "demo", "--", "literal"])
    s.settings(newJObject())
    let r = s.run(binary, @["exec", "demo", "--", "literal"])
    check r.code == 0
    check r.output == ""
    check r.error == ""
    s.noHistory()

  test "lock spans guest lifetime and releases without history changes":
    for recipe in [false, true]:
      if recipe: s.managed()
      createDir(s.home / ".ocdev/runs/logs")
      let history = s.home / ".ocdev/runs/existing.json"
      let log = s.home / ".ocdev/runs/logs/existing.json"
      writeFile(history, "unchanged-history")
      writeFile(log, "unchanged-log")
      let child = s.start(binary, @["exec", "demo", "--", "block"])
      if not waitFor(s.home / "exec-ready"):
        raise newException(IOError, "Execution did not reach fixture barrier")
      expect IOError:
        let fd = acquireLock(s.lockPath)
        releaseLock(fd)
      writeFile(s.home / "release", "go")
      check child.finish().code == 0
      s.lockAvailable()
      check readFile(history) == "unchanged-history"
      check readFile(log) == "unchanged-log"
      removeFile(history)
      removeFile(log)
      s.noHistory()
      removeFile(s.home / "exec-ready")
      removeFile(s.home / "release")

  test "queued repeated cancellation keeps cleanup and reaping intact":
    for blockList in [false, true]:
      s.settings(%*{"blockList": blockList, "ignoreSignals": true})
      let child = s.start(binary, @["exec", "demo", "--", "block"])
      let marker = s.home / (if blockList: "list-ready" else: "exec-ready")
      try:
        if not waitFor(marker): raise newException(IOError, "Missing cancellation barrier")
        let incusPid = Pid(parseInt(readFile(s.home / "incus.pid")))
        check kill(child.pid, SIGSTOP) == 0
        var stopped = false
        for attempt in 0 ..< 1000:
          var status: cint
          let waited = waitpid(child.pid, status, WUNTRACED or WNOHANG)
          if waited == child.pid:
            stopped = WIFSTOPPED(status)
            break
          if waited < 0 and errno != EINTR: raise newException(IOError, "Cannot observe stopped controller")
          sleep(1)
        if not stopped: raise newException(IOError, "Controller did not stop")
        # Queue both signals while the execution scope is definitely active;
        # neither signal can race with restoring handlers after process exit.
        for attempt in 0 ..< 20:
          check kill(child.pid, SIGINT) == 0
          check kill(child.pid, SIGTERM) == 0
        check kill(child.pid, SIGCONT) == 0
        let r = child.finish(7000, cleanupGroup = false)
        check r.code in [128 + int(SIGINT), 128 + int(SIGTERM)]
        check r.output == ""
        check r.error == ""
        check kill(incusPid, 0) == -1
        check errno == ESRCH
        s.lockAvailable()
        s.noHistory()
      finally:
        discard killpg(child.pid, SIGKILL)
      removeFile(marker)
      if fileExists(s.home / "signal"): removeFile(s.home / "signal")

  test "INT and TERM cancel and reap cooperative or stubborn Incus":
    for blockList in [false, true]:
      for ignores in [false, true]:
        for sig in [SIGINT, SIGTERM]:
          s.settings(%*{"blockList": blockList, "ignoreSignals": ignores})
          let child = s.start(binary, @["exec", "demo", "--", "block"])
          let marker = s.home / (if blockList: "list-ready" else: "exec-ready")
          if not waitFor(marker):
            raise newException(IOError, "Execution did not reach cancellation barrier")
          let incusPid = Pid(parseInt(readFile(s.home / "incus.pid")))
          try:
            check kill(child.pid, sig) == 0
            if not blockList:
              if not waitFor(s.home / "signal"):
                raise newException(IOError, "Signal was not forwarded to Incus client")
              check readFile(s.home / "signal") == $sig
            # A read-only preflight query can be killed immediately. The raw
            # execution client first receives the signal and a bounded grace.
            let r = child.finish(7000, cleanupGroup = false)
            check r.code == 128 + int(sig)
            check r.output == ""
            check r.error == ""
            check kill(incusPid, 0) == -1
            check errno == ESRCH
            s.lockAvailable()
            s.noHistory()
          finally:
            discard killpg(child.pid, SIGKILL)
          removeFile(marker)
          if fileExists(s.home / "signal"): removeFile(s.home / "signal")
