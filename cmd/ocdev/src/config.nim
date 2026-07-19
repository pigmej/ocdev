## Configuration constants and types for ocdev
import std/os

const
  Version* = "0.1.2"
  ContainerPrefix* = "ocdev-"
  ProfileName* = "ocdev"
  BaseImage* = "images:ubuntu/25.10"
  SshPortStart* = 2200
  ServicePortStart* = 2300
  PortsPerVm* = 10
  ServicePortsCount* = 10
  MaxNameLength* = 50
  HerdrDeviceName* = "host-herdr"
  HerdrContainerPath* = "/home/dev/.config/herdr"
  HerdrDirectoryPermissions* = {fpUserRead, fpUserWrite, fpUserExec}
  HostDiskDeviceNames* = [
    HerdrDeviceName,
    "host-config",
    "host-opencode",
    "host-claude",
    "host-codex",
    "host-omp",
    "host-ssh",
    "host-gitconfig",
    "host-oc-share",
    "host-oc-state"
  ]

# Runtime computed paths (can't be const because getHomeDir is runtime)
proc getOcdevDir*(): string =
  getHomeDir() / ".ocdev"

proc getPortsFile*(): string =
  getOcdevDir() / "ports"

proc getLockFile*(): string =
  getOcdevDir() / ".lock"

proc getHerdrDir*(homeDir, fullInstanceName: string): string =
  ## Return the host directory used for an instance's isolated Herdr state.
  homeDir / ".local" / "share" / "ocdev" / "herdr" / fullInstanceName

proc getInstanceHerdrDir*(fullInstanceName: string): string =
  getHerdrDir(getHomeDir(), fullInstanceName)

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
