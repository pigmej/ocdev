## Container state helper functions
import std/[osproc, strutils]
import config

proc containerExists*(name: string): bool =
  ## Check if container exists by running 'incus info <name>'
  ## Returns true if exit code is 0
  let fullName = ContainerPrefix & name
  let (_, exitCode) = execCmdEx("incus info " & fullName & " 2>/dev/null")
  result = exitCode == 0

proc containerRunning*(name: string): bool =
  ## Check if container is running by parsing 'incus info' output
  ## Looks for 'Status: RUNNING' line
  let fullName = ContainerPrefix & name
  let (output, exitCode) = execCmdEx("incus info " & fullName & " 2>/dev/null")
  if exitCode != 0:
    return false
  # Parse output for "Status: RUNNING"
  for line in output.splitLines():
    if line.startsWith("Status:"):
      return "RUNNING" in line
  result = false

proc validateName*(name: string): tuple[valid: bool, msg: string] =
  ## Validate container name format
  ## Must start with letter, contain only alphanumeric and hyphens, max 50 chars
  if name.len == 0:
    return (false, "Name cannot be empty")
  if name.len > MaxNameLength:
    return (false, "Name too long (max " & $MaxNameLength & " chars)")
  if not name[0].isAlphaAscii():
    return (false, "Name must start with a letter")
  for c in name:
    if not (c.isAlphaNumeric() or c == '-'):
      return (false, "Name can only contain alphanumeric characters and hyphens")
  result = (true, "")
