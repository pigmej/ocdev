## Linux-only black-box test support. No Python or live Incus dependency.
## Each command gets a private session and file-backed, separately captured
## streams so large output cannot deadlock the test runner's pipe buffers.
import std/[os, json, strtabs, tempfiles, posix, monotimes, times]

export strtabs

type
  TestProcessTimeout* = object of CatchableError
  RunResult* = object
    code*: int
    output*, error*: string
  Child* = ref object
    pid*: Pid
    directory: string
    finished: bool
  Sandbox* = ref object
    home*: string
    env*: StringTableRef
    children: seq[Child]

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}
proc immediateExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc pathExists*(path: string): bool =
  fileExists(path) or dirExists(path) or symlinkExists(path)

proc readJson*(path: string): JsonNode = parseJson(readFile(path))
proc writeJson*(path: string; value: JsonNode) = writeFile(path, $value)

proc newSandbox*(prefix: string; fakeBinary = ""): Sandbox =
  if fakeBinary.len > 0:
    doAssert fileExists(fakeBinary), "Build the fake Incus fixture first"
  result = Sandbox(home: createTempDir(prefix, ""), env: newStringTable(modeCaseSensitive))
  setFilePermissions(result.home, {fpUserRead, fpUserWrite, fpUserExec})
  for key, value in envPairs(): result.env[key] = value
  # Do not let a developer's fake-backend switches influence another test.
  for key in ["BAD_LIST", "BAD_SERVICES", "BAD_METADATA", "DRIVER",
              "MISSING_SNAPSHOT", "EXEC_SEEDS", "FAIL_COPY", "FAIL_HOOK",
              "FAIL_FINAL_INFO", "FAIL_START", "WAIT_COPY", "WAIT_ABSENCE",
              "SWITCH_REBIND_OWNER", "FAKE_STATE", "FAKE_TRACE", "FAKE_ROOT"]:
    result.env.del(key)
  result.env["HOME"] = result.home
  result.env["PATH"] = result.home & ":" & getEnv("PATH")
  if fakeBinary.len > 0:
    copyFile(fakeBinary, result.home / "incus")
    setFilePermissions(result.home / "incus", {fpUserRead, fpUserWrite, fpUserExec})

proc acquireLock*(path: string): cint =
  result = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
  if result < 0: raiseOSError(osLastError())
  if flock(result, 2 or 4) != 0:
    discard posix.close(result)
    raise newException(IOError, "Test lock already held")

proc releaseLock*(fd: cint) =
  discard flock(fd, 8)
  discard posix.close(fd)

proc start*(s: Sandbox; binary: string; args: seq[string]): Child =
  doAssert binary.isAbsolute and fileExists(binary), "Pass a freshly built absolute binary path"
  result = Child(directory: createTempDir("capture-", "", s.home))
  let outPath = result.directory / "stdout"
  let errPath = result.directory / "stderr"
  let outFd = posix.open(outPath.cstring, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
  if outFd < 0: raiseOSError(osLastError())
  defer: discard posix.close(outFd)
  let errFd = posix.open(errPath.cstring, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
  if errFd < 0: raiseOSError(osLastError())
  defer: discard posix.close(errFd)
  let inFd = posix.open("/dev/null", O_RDONLY)
  if inFd < 0: raiseOSError(osLastError())
  defer: discard posix.close(inFd)
  var env: seq[string]
  for key, value in s.env: env.add(key & "=" & value)
  let argv = allocCStringArray(@[binary] & args)
  let envp = allocCStringArray(env)
  defer:
    deallocCStringArray(argv)
    deallocCStringArray(envp)
  let pid = fork()
  if pid < 0: raiseOSError(osLastError())
  if pid == 0:
    if setsid() < 0: immediateExit(126)
    if dup2(inFd, STDIN_FILENO) < 0 or dup2(outFd, STDOUT_FILENO) < 0 or
        dup2(errFd, STDERR_FILENO) < 0: immediateExit(126)
    discard posix.close(inFd)
    discard posix.close(outFd)
    discard posix.close(errFd)
    discard execve(binary.cstring, argv, envp)
    immediateExit(127)
  result.pid = pid
  s.children.add(result)

proc reap(child: Child; killFirst: bool; timeoutMs: int; cleanupGroup = true): RunResult =
  doAssert not child.finished, "Child already collected"
  var status: cint
  var timedOut = killFirst
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  if killFirst:
    discard killpg(child.pid, SIGKILL)
    discard kill(child.pid, SIGKILL) # also handles the short pre-setsid window
  while true:
    let waited = waitpid(child.pid, status, WNOHANG)
    if waited == child.pid: break
    if waited < 0:
      if errno == EINTR: continue
      raiseOSError(osLastError())
    if not timedOut and getMonoTime() >= deadline:
      timedOut = true
      discard killpg(child.pid, SIGKILL)
      discard kill(child.pid, SIGKILL)
    sleep(5)
  # Fixtures must not leave descendants behind after the command exits.
  if cleanupGroup: discard killpg(child.pid, SIGKILL)
  child.finished = true
  result.code = if timedOut: 124
                elif WIFEXITED(status): int(WEXITSTATUS(status))
                else: 128 + int(WTERMSIG(status))
  result.output = readFile(child.directory / "stdout")
  result.error = readFile(child.directory / "stderr")
  removeDir(child.directory)
  if timedOut and not killFirst:
    raise newException(TestProcessTimeout, "Test subprocess exceeded its deadline")

proc finish*(child: Child; timeoutMs = 20000; cleanupGroup = true): RunResult =
  ## Disable group cleanup only when a test verifies reaping itself and supplies
  ## its own finally cleanup; otherwise this would conceal leaked descendants.
  reap(child, false, timeoutMs, cleanupGroup)
proc run*(s: Sandbox; binary: string; args: seq[string]; timeoutMs = 20000): RunResult =
  finish(start(s, binary, args), timeoutMs)

proc close*(s: Sandbox) =
  if s.isNil: return
  for child in s.children:
    if not child.finished: discard reap(child, true, 0)
  if dirExists(s.home): removeDir(s.home)
