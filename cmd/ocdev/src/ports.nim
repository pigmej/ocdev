## Port allocation management with POSIX file locking
import std/[os, strutils, posix]
import config

# POSIX flock constants
const
  LOCK_SH = 1.cint  # Shared lock
  LOCK_EX = 2.cint  # Exclusive lock
  LOCK_UN = 8.cint  # Unlock

# Import flock from system
proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc withLock*[T](exclusive: bool, body: proc(): T): T =
  ## Execute body with file lock held
  ## Creates lock file if needed, ensures cleanup
  createDir(OcdevDir)
  let fd = open(LockFile.cstring, O_CREAT or O_RDWR, 0o644)
  if fd < 0:
    raise newException(IOError, "Cannot open lock file: " & LockFile)
  defer: discard close(fd)
  
  let lockType = if exclusive: LOCK_EX else: LOCK_SH
  if flock(fd.cint, lockType) != 0:
    raise newException(IOError, "Cannot acquire lock")
  defer: discard flock(fd.cint, LOCK_UN)
  
  result = body()

proc withLockVoid*(exclusive: bool, body: proc()) =
  ## Execute body with file lock held (no return value variant)
  ## Creates lock file if needed, ensures cleanup
  createDir(OcdevDir)
  let fd = open(LockFile.cstring, O_CREAT or O_RDWR, 0o644)
  if fd < 0:
    raise newException(IOError, "Cannot open lock file: " & LockFile)
  defer: discard close(fd)
  
  let lockType = if exclusive: LOCK_EX else: LOCK_SH
  if flock(fd.cint, lockType) != 0:
    raise newException(IOError, "Cannot acquire lock")
  defer: discard flock(fd.cint, LOCK_UN)
  
  body()

proc readAllocatedPorts*(): seq[int] =
  ## Read all allocated ports from ports file
  result = @[]
  if not fileExists(PortsFile):
    return
  for line in lines(PortsFile):
    let parts = line.strip().split(':')
    if parts.len >= 2:
      try:
        result.add(parseInt(parts[1]))
      except ValueError:
        discard  # Skip malformed lines

proc getServicePortBase*(sshPort: int): int =
  ## Calculate service port base from SSH port
  ## SSH 2200 -> service base 2300, SSH 2210 -> service base 2310
  result = ServicePortStart + (sshPort - SshPortStart)

proc rangesOverlap(startA, endA, startB, endB: int): bool =
  startA <= endB and startB <= endA

proc isPortBlockAvailable*(sshPort: int, allocatedSshPorts: seq[int]): bool =
  ## Check whether a candidate SSH port and its service range are free.
  ## Each ocdev container reserves its SSH port plus ServicePortsCount service
  ## ports derived from that SSH port. Without this check, SSH port 2300 can
  ## collide with the first container's service range 2300-2309.
  let serviceStart = getServicePortBase(sshPort)
  let serviceEnd = serviceStart + ServicePortsCount - 1
  if sshPort < 1 or sshPort > 65535 or serviceEnd > 65535:
    return false

  for allocatedSsh in allocatedSshPorts:
    let allocatedServiceStart = getServicePortBase(allocatedSsh)
    let allocatedServiceEnd = allocatedServiceStart + ServicePortsCount - 1
    if sshPort == allocatedSsh:
      return false
    if sshPort >= allocatedServiceStart and sshPort <= allocatedServiceEnd:
      return false
    if allocatedSsh >= serviceStart and allocatedSsh <= serviceEnd:
      return false
    if rangesOverlap(serviceStart, serviceEnd, allocatedServiceStart, allocatedServiceEnd):
      return false
  result = true

proc allocatePort*(): int =
  ## Find next available SSH port (called within lock context).
  ## Ports increment by PORTS_PER_VM (10) starting at SSH_PORT_START (2200),
  ## while avoiding both existing SSH ports and existing service port ranges.
  let allocated = readAllocatedPorts()
  var port = SshPortStart
  while not isPortBlockAvailable(port, allocated):
    port += PortsPerVm
    if port > 65535 or getServicePortBase(port) + ServicePortsCount - 1 > 65535:
      raise newException(ValueError, "No available ports (all from " & 
                         $SshPortStart & " are allocated)")
  result = port

proc savePortAllocation*(name: string, port: int) =
  ## Append port allocation to ports file (called within lock context)
  createDir(OcdevDir)
  let f = open(PortsFile, fmAppend)
  defer: f.close()
  f.writeLine(name & ":" & $port)

proc removePort*(name: string) =
  ## Remove port allocation for container (with exclusive lock)
  withLockVoid(exclusive = true) do ():
    if not fileExists(PortsFile):
      return
    var newLines: seq[string] = @[]
    for line in lines(PortsFile):
      if not line.startsWith(name & ":"):
        newLines.add(line)
    if newLines.len > 0:
      writeFile(PortsFile, newLines.join("\n") & "\n")
    else:
      writeFile(PortsFile, "")

proc getPort*(name: string): int =
  ## Get allocated SSH port for container (0 if not found)
  if not fileExists(PortsFile):
    return 0
  for line in lines(PortsFile):
    let parts = line.strip().split(':')
    if parts.len >= 2 and parts[0] == name:
      try:
        return parseInt(parts[1])
      except ValueError:
        return 0
  result = 0
