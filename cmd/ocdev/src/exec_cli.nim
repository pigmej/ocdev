## Dedicated parsing for raw command execution: guest flags are never ocdev flags.
import std/[os, strutils]
import config, container, recipe_engine, exec_transport

const ExecHelp* = """Usage:
  ocdev exec <name> [--cwd <absolute-path>] -- <command> [args...]

Run a command as dev in an existing, running container (default cwd: /home/dev).
Forward stdin, stdout, stderr and exit status directly, without a pseudo-terminal.
Everything after -- belongs to the command, including --help and --json.
No implicit shell, startup files, timeout, or command/output history.
Use ocdev shell for an interactive terminal, or explicitly run sh -c for shell syntax.
"""

proc dispatchExec*(args: seq[string]): tuple[handled: bool, code: int] =
  result.handled = true
  try:
    var name = ""
    var nameSet = false
    var cwd = "/home/dev"
    var cwdSet = false
    var i = 0
    while i < args.len and args[i] != "--":
      let arg = args[i]
      if arg in ["--help", "-h"]:
        stdout.write(ExecHelp)
        return (true, 0)
      elif arg == "--cwd" or arg.startsWith("--cwd="):
        if cwdSet: raise newException(ValueError, "Specify --cwd only once")
        cwdSet = true
        if arg == "--cwd":
          inc i
          if i >= args.len or args[i] == "--":
            raise newException(ValueError, "--cwd requires an absolute path")
          cwd = args[i]
        else: cwd = arg[6 .. ^1]
      elif arg.startsWith("-"):
        raise newException(ValueError, "Unknown exec option; see ocdev exec --help")
      elif not nameSet:
        name = arg
        nameSet = true
      else: raise newException(ValueError, "Put the command after --; see ocdev exec --help")
      inc i
    if not validateName(name).valid:
      raise newException(ValueError, "Invalid or missing container name")
    if not cwd.isAbsolute or '\0' in cwd:
      raise newException(ValueError, "--cwd requires an absolute path")
    if i >= args.len or i + 1 >= args.len or args[i + 1].len == 0:
      raise newException(ValueError, "A command after -- is required; see ocdev exec --help")
    let command = args[i + 1 .. ^1]
    let invocation = @["incus", "exec", ContainerPrefix & name,
      "--mode=non-interactive", "--cwd", cwd, "--", "runuser", "-u", "dev", "--"] & command
    result.code = withExecSignals(proc(): int =
      withRunningEnvironment(name, proc(): int = streamExec(invocation), interrupted))
  except CatchableError as error:
    stderr.writeLine("Error: " & error.msg)
    result.code = 1
