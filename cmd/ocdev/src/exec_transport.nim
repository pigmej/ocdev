## Raw foreground transport for `ocdev exec`. No capture, shell, or output logs.
import std/[os, posix, monotimes, times]

const CancelGraceMs = 2000
var receivedSignal {.volatile.}: cint

proc rememberSignal(signal: cint) {.noconv.} =
  # Only signal-safe scalar access here; cleanup happens in the polling loop.
  if receivedSignal == 0: receivedSignal = signal

proc interrupted*(): bool = receivedSignal != 0

proc withExecSignals*(body: proc(): int {.closure.}): int =
  var action, oldInt, oldTerm: Sigaction
  action.sa_handler = rememberSignal
  discard sigemptyset(action.sa_mask)
  # Serialize INT/TERM handlers so the first-signal check cannot be interrupted
  # by the other handler between its read and write.
  discard sigaddset(action.sa_mask, SIGINT)
  discard sigaddset(action.sa_mask, SIGTERM)
  receivedSignal = 0
  if sigaction(SIGINT, action, oldInt) != 0:
    raise newException(IOError, "Cannot install execution signal handler")
  defer: discard sigaction(SIGINT, oldInt)
  if sigaction(SIGTERM, action, oldTerm) != 0:
    raise newException(IOError, "Cannot install execution signal handler")
  defer:
    discard sigaction(SIGTERM, oldTerm)
    receivedSignal = 0
  try:
    let code = body()
    result = if interrupted(): 128 + int(receivedSignal) else: code
  except CatchableError:
    if not interrupted(): raise
    result = 128 + int(receivedSignal)

proc exitImmediately(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc streamExec*(args: seq[string]): int =
  ## Keep ocdev alive to own the environment lock until the Incus client is reaped.
  ## The client shares our foreground group, allowing terminal stdin without a PTY.
  if interrupted(): return 128 + int(receivedSignal)
  if args.len == 0: raise newException(ValueError, "Missing executable")
  let argv = allocCStringArray(args)
  defer: deallocCStringArray(argv)
  var blocked, previousMask, ignoredMask: Sigset
  discard sigemptyset(blocked)
  discard sigaddset(blocked, SIGINT)
  discard sigaddset(blocked, SIGTERM)
  if sigprocmask(SIG_BLOCK, blocked, previousMask) != 0:
    raise newException(IOError, "Cannot prepare execution signal mask")
  let pid = fork()
  if pid == 0:
    var action: Sigaction
    action.sa_handler = SIG_DFL
    discard sigemptyset(action.sa_mask)
    discard sigaction(SIGINT, action)
    discard sigaction(SIGTERM, action)
    discard sigprocmask(SIG_SETMASK, previousMask, ignoredMask)
    discard execvp(argv[0], argv)
    const message = "Error: unable to start Incus client.\n"
    discard posix.write(STDERR_FILENO, message.cstring, message.len)
    exitImmediately(127)
  discard sigprocmask(SIG_SETMASK, previousMask, ignoredMask)
  if pid < 0: raise newException(IOError, "Cannot start Incus client")
  var reaped = false
  defer:
    if not reaped:
      discard kill(pid, SIGKILL)
      var status: cint
      while waitpid(pid, status, 0) < 0 and errno == EINTR: discard
  var cancelling = false
  var killed = false
  var cancelStarted: MonoTime
  while true:
    var status: cint
    let waited = waitpid(pid, status, WNOHANG)
    if waited == pid:
      reaped = true
      if WIFEXITED(status): return int(WEXITSTATUS(status))
      if WIFSIGNALED(status): return 128 + int(WTERMSIG(status))
      raise newException(IOError, "Unexpected Incus client exit status")
    if waited < 0:
      if errno == EINTR: continue
      if errno == ECHILD: reaped = true
      raise newException(IOError, "Cannot collect Incus client exit status")
    if interrupted() and not cancelling:
      cancelling = true
      cancelStarted = getMonoTime()
      discard kill(pid, receivedSignal)
    if cancelling and not killed and (getMonoTime() - cancelStarted).inMilliseconds >= CancelGraceMs:
      discard kill(pid, SIGKILL)
      killed = true
    sleep(5)
