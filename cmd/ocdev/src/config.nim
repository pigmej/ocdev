## Configuration constants and types for ocdev
import std/os

const
  Version* = "0.1.0"
  ContainerPrefix* = "ocdev-"
  ProfileName* = "ocdev"
  BaseImage* = "images:ubuntu/25.10"
  SshPortStart* = 2200
  ServicePortStart* = 2300
  PortsPerVm* = 10
  ServicePortsCount* = 10
  MaxNameLength* = 50

# Runtime computed paths (can't be const because getHomeDir is runtime)
proc getOcdevDir*(): string =
  getHomeDir() / ".ocdev"

proc getPortsFile*(): string =
  getOcdevDir() / "ports"

proc getLockFile*(): string =
  getOcdevDir() / ".lock"

# Convenience aliases for backward compatibility
template OcdevDir*: string = getOcdevDir()
template PortsFile*: string = getPortsFile()
template LockFile*: string = getLockFile()

type
  ExitCode* = enum
    ecSuccess = 0       ## Operation succeeded
    ecError = 1         ## General error
    ecPrereq = 2        ## Prerequisite check failed
    ecNotFound = 3      ## Container not found
    ecNotRunning = 4    ## Container not running
