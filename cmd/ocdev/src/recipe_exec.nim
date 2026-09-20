## Argument-safe, bounded subprocess transport. Never include output in errors.
import std/[os, osproc, posix, monotimes, times, streams]

type
  CancellationCheck* = proc(): bool {.closure.}
  ExecResult* = object
    code*: int
    output*: string
    truncated*: bool

proc stillRunning(p: Process): bool =
  while true:
    try: return p.running()
    except OSError as error:
      if error.errorCode != int32(EINTR): raise

proc waitUninterrupted(p: Process): int =
  # osproc.waitForExit does not retry an interrupted waitpid on Linux.
  while true:
    try: return p.waitForExit()
    except OSError as error:
      if error.errorCode != int32(EINTR): raise

proc execute*(args: seq[string]; input = ""; timeoutMs = 30000;
              limit = 65536; cancelled: CancellationCheck = nil): ExecResult =
  if args.len == 0: raise newException(ValueError, "Missing executable")
  if cancelled != nil and cancelled(): raise newException(IOError, "Execution cancelled")
  var p: Process
  try:
    p = startProcess(args[0], args = args[1..^1], options = {poUsePath, poStdErrToStdOut})
  except CatchableError:
    raise newException(IOError, "Executable could not be started")
  defer:
    # All exits after spawning, including cancellation and I/O errors, must
    # collect the client before the caller can release its environment lock.
    try:
      if stillRunning(p): p.kill()
      discard waitUninterrupted(p)
    finally: p.close()
  let outf = cint(p.outputHandle)
  let inf = cint(p.inputHandle)
  discard fcntl(outf, F_SETFL, fcntl(outf, F_GETFL) or O_NONBLOCK)
  discard fcntl(inf, F_SETFL, fcntl(inf, F_GETFL) or O_NONBLOCK)
  # Ignore SIGPIPE when a process exits before consuming its input.
  var oldSignal, ignored: Sigaction
  ignored.sa_handler = SIG_IGN
  discard sigemptyset(ignored.sa_mask)
  discard sigaction(SIGPIPE, ignored, oldSignal)
  defer: discard sigaction(SIGPIPE, oldSignal, ignored)
  var sent = 0
  var inputClosed = false
  let started = getMonoTime()
  var buf: array[8192, char]
  while true:
    if cancelled != nil and cancelled():
      raise newException(IOError, "Execution cancelled")
    if not inputClosed:
      if sent < input.len:
        let n = posix.write(inf, unsafeAddr input[sent], min(8192, input.len - sent))
        if n > 0: sent += n
        elif n < 0 and errno != EAGAIN and errno != EINTR:
          inputClosed = true
          p.inputStream.close()
      if sent == input.len and not inputClosed:
        p.inputStream.close()
        inputClosed = true
    var drained = false
    while true:
      let n = posix.read(outf, addr buf[0], buf.len)
      if n <= 0:
        drained = true
        break
      let keep = min(n, max(0, limit - result.output.len))
      for i in 0..<keep: result.output.add(buf[i])
      if keep < n: result.truncated = true
      if (getMonoTime() - started).inMilliseconds > timeoutMs or
          (cancelled != nil and cancelled()): break
    if not stillRunning(p) and drained:
      result.code = waitUninterrupted(p)
      break
    if (getMonoTime() - started).inMilliseconds > timeoutMs:
      result.code = 124
      break
    sleep(5)
