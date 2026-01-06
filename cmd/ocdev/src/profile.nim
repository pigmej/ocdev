## Incus profile management
import std/osproc
import config, output

proc ensureProfile*() =
  ## Create ocdev profile if it doesn't exist
  ## Sets security options for Docker-in-container support
  let (_, exitCode) = execCmdEx("incus profile show " & ProfileName & " 2>/dev/null")
  if exitCode != 0:
    info("Creating ocdev profile...")
    discard execCmd("incus profile create " & ProfileName)
    discard execCmd("incus profile set " & ProfileName & " security.nesting=true")
    discard execCmd("incus profile set " & ProfileName & " security.syscalls.intercept.mknod=true")
    discard execCmd("incus profile set " & ProfileName & " security.syscalls.intercept.setxattr=true")
