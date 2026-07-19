## Command implementations for ocdev
import std/[os, osproc, strutils, strformat, posix, json]
import config, output, container, ports, profile, provision, postinstall

const
  MinPort = 1
  MaxPort = 65535

proc inspectDeviceNames(containerName: string): tuple[names: seq[string], err: string] =
  ## Return local device names, distinguishing an empty list from inspection failure.
  let (output, exitCode) = execCmdEx("incus config device list " &
    quoteShell(containerName) & " 2>&1")
  if exitCode != 0:
    return (@[], fmt"Failed to inspect devices on '{containerName}': {output.strip()}")
  for line in output.strip().splitLines():
    let deviceName = line.strip()
    if deviceName.len > 0:
      result.names.add(deviceName)

proc inspectDevicePresence(containerName, deviceName: string): tuple[exists: bool, err: string] =
  let (deviceNames, inspectErr) = inspectDeviceNames(containerName)
  if inspectErr.len > 0:
    return (false, inspectErr)
  return (deviceName in deviceNames, "")

proc deviceExists(containerName, deviceName: string): bool =
  ## Best-effort device check for non-critical lookup paths.
  let (exists, _) = inspectDevicePresence(containerName, deviceName)
  return exists

proc getDeviceProperty(containerName, deviceName, propertyName: string): tuple[value, err: string] =
  let (output, exitCode) = execCmdEx("incus config device get " &
    quoteShell(containerName) & " " & quoteShell(deviceName) & " " &
    quoteShell(propertyName) & " 2>&1")
  if exitCode != 0:
    return ("", fmt"Failed to inspect {propertyName} for device '{deviceName}' on '{containerName}': {output.strip()}")
  return (output.strip(), "")

proc herdrDeviceMatches*(deviceType, sourcePath, targetPath, expectedSource: string): bool =
  ## Pure comparison used before accepting an existing host-herdr device.
  deviceType == "disk" and sourcePath == expectedSource and targetPath == HerdrContainerPath

proc parseInstanceRunningState*(output: string): tuple[known, running: bool] =
  ## Parse Incus' human-readable status without treating missing status as stopped.
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("Status:"):
      let status = stripped["Status:".len .. ^1].strip()
      return (true, status == "RUNNING")
  return (false, false)

proc inspectInstanceRunning(containerName: string): tuple[running: bool, err: string] =
  let (output, exitCode) = execCmdEx("incus info " & quoteShell(containerName) & " 2>&1")
  if exitCode != 0:
    return (false, fmt"Failed to inspect state for '{containerName}': {output.strip()}")
  let state = parseInstanceRunningState(output)
  if not state.known:
    return (false, fmt"Failed to determine running state for '{containerName}'")
  return (state.running, "")

proc incusConfirmsAbsent*(exitCode: int, output: string): bool =
  ## A failed inspection confirms absence only when Incus explicitly identifies
  ## the instance itself as missing, not for unrelated connection/project errors.
  let message = output.toLowerAscii()
  exitCode != 0 and ("instance not found" in message or
    "instance does not exist" in message)

proc mayRemoveHerdrAfterCleanup*(deleteExitCode, inspectExitCode: int,
                                 inspectOutput: string): bool =
  deleteExitCode == 0 or incusConfirmsAbsent(inspectExitCode, inspectOutput)

proc inspectInstanceAbsent(containerName: string): tuple[absent: bool, err: string] =
  ## Confirm that a destination instance is absent before resetting host-side state.
  let (output, exitCode) = execCmdEx("incus info " & quoteShell(containerName) & " 2>&1")
  if exitCode == 0:
    return (false, "")
  if incusConfirmsAbsent(exitCode, output):
    return (true, "")
  return (false, fmt"Failed to confirm that '{containerName}' is absent: {output.strip()}")

proc mayRestartAfterExport*(wasRunning: bool, restorationFailureCount: int): bool =
  wasRunning and restorationFailureCount == 0

proc parsePortArg*(portArg: string): tuple[containerPort, hostPort: int, valid: bool, errMsg: string] =
  ## Parse port argument: "PORT" or "CONTAINER_PORT:HOST_PORT"
  ## Returns (containerPort, hostPort, valid, errorMessage)
  if ':' in portArg:
    let parts = portArg.split(':')
    if parts.len != 2:
      return (0, 0, false, "Invalid port format. Use PORT or CONTAINER_PORT:HOST_PORT")
    let containerPort = try: parseInt(parts[0]) except ValueError: 0
    let hostPort = try: parseInt(parts[1]) except ValueError: 0
    if containerPort == 0 or hostPort == 0:
      return (0, 0, false, "Invalid port numbers")
    if containerPort < MinPort or containerPort > MaxPort:
      return (0, 0, false, fmt"Container port must be between {MinPort} and {MaxPort}")
    if hostPort < MinPort or hostPort > MaxPort:
      return (0, 0, false, fmt"Host port must be between {MinPort} and {MaxPort}")
    return (containerPort, hostPort, true, "")
  else:
    let port = try: parseInt(portArg) except ValueError: 0
    if port == 0:
      return (0, 0, false, "Invalid port number")
    if port < MinPort or port > MaxPort:
      return (0, 0, false, fmt"Port must be between {MinPort} and {MaxPort}")
    return (port, port, true, "")

type
  CloneSourceKind* = enum
    cskContainer,
    cskSnapshot
  CloneSource* = object
    kind*: CloneSourceKind
    container*: string
    snapshot*: string

proc parseCloneSource*(`from`: string): tuple[source: CloneSource, valid: bool, errMsg: string] =
  ## Parse clone source: "container" or "container/snapshot"
  if `from`.len == 0:
    return (CloneSource(), false, "Invalid clone source. Use: container or container/snapshot")

  let parts = `from`.split('/')
  if parts.len < 1 or parts.len > 2:
    return (CloneSource(), false, "Invalid clone source. Use: container or container/snapshot")

  let container = parts[0]
  let snapshot = if parts.len == 2: parts[1] else: ""
  if container.len == 0 or (parts.len == 2 and snapshot.len == 0):
    return (CloneSource(), false, "Invalid clone source. Use: container or container/snapshot")

  let (containerValid, containerMsg) = validateName(container)
  if not containerValid:
    return (CloneSource(), false, "Invalid source container name: " & containerMsg)

  if parts.len == 1:
    return (CloneSource(kind: cskContainer, container: container), true, "")

  return (CloneSource(kind: cskSnapshot, container: container, snapshot: snapshot), true, "")


const
  DynDevicePrefix = "dyn-"
  TcpConnectPrefix = "tcp:127.0.0.1:"

proc getDynamicBindings(containerName: string): seq[tuple[hostPort, containerPort: int]] =
  ## Get all dynamic port bindings (dyn-* devices) for a container
  var bindings: seq[tuple[hostPort, containerPort: int]] = @[]
  
  let (deviceList, exitCode) = execCmdEx(fmt"incus config device list {containerName}")
  if exitCode != 0:
    return bindings
  
  for line in deviceList.strip().splitLines():
    let deviceName = line.strip()
    if deviceName.startsWith(DynDevicePrefix):
      # Extract host port from device name
      let hostPortStr = deviceName[DynDevicePrefix.len..^1]
      let hostPort = try: parseInt(hostPortStr) except ValueError: -1
      if hostPort < 0:
        warn(fmt"Skipping malformed dynamic binding device: {deviceName}")
        continue
      if hostPort > 0:
        # Get device details to find container port
        let (deviceInfo, _) = execCmdEx(fmt"incus config device get {containerName} {deviceName} connect")
        # Format: tcp:127.0.0.1:<port>
        let connectStr = deviceInfo.strip()
        if connectStr.startsWith(TcpConnectPrefix):
          let containerPortStr = connectStr[TcpConnectPrefix.len..^1]
          let containerPort = try: parseInt(containerPortStr) except ValueError: -1
          if containerPort < 0:
            warn(fmt"Skipping malformed container port in {deviceName}: {connectStr}")
            continue
          if containerPort > 0:
            bindings.add((hostPort, containerPort))
        else:
          warn(fmt"Unexpected connect format for {deviceName}: {connectStr}")
  
  result = bindings

proc findPortBinding(hostPort: int): string =
  ## Find which container (if any) has a specific host port dynamically bound.
  ## Returns full container name (with prefix) or empty string if not found.
  let (output, exitCode) = execCmdEx("incus list --format csv -c n")
  if exitCode != 0:
    return ""
  let deviceName = fmt"dyn-{hostPort}"
  for line in output.strip().splitLines():
    let containerName = line.strip()
    if not containerName.startsWith(ContainerPrefix):
      continue
    if deviceExists(containerName, deviceName):
      return containerName
  return ""

proc getProxyDevices(containerName: string): tuple[devices: seq[string], err: string] =
  ## Get all local proxy devices on a container, propagating inspection errors.
  ## Cloned containers inherit source proxy devices, including ad-hoc host-* proxies.
  let (deviceNames, inspectErr) = inspectDeviceNames(containerName)
  if inspectErr.len > 0:
    return (@[], inspectErr)

  for deviceName in deviceNames:
    let (deviceType, typeErr) = getDeviceProperty(containerName, deviceName, "type")
    if typeErr.len > 0:
      return (@[], typeErr)
    if deviceType == "proxy":
      result.devices.add(deviceName)

proc reconfigureProxyDevices(containerName: string, port: int): int =
  ## Remove inherited proxy devices and add new ones with correct ports.
  ## All local proxy devices must be removed because copied host-* proxies can
  ## conflict with the source container when the clone starts.
  let (proxyDevices, proxyInspectErr) = getProxyDevices(containerName)
  if proxyInspectErr.len > 0:
    error(proxyInspectErr)
    return ord(ecError)
  var devicesToRemove = proxyDevices

  # Keep the old name-based fallback for compatibility with standard devices.
  var fallbackDevices = @["ssh-proxy"]
  for i in 0 ..< ServicePortsCount:
    fallbackDevices.add("svc-proxy-" & $i)
  let dynamicBindings = getDynamicBindings(containerName)
  for binding in dynamicBindings:
    fallbackDevices.add("dyn-" & $binding.hostPort)
  for device in fallbackDevices:
    if device notin devicesToRemove:
      let (exists, presenceErr) = inspectDevicePresence(containerName, device)
      if presenceErr.len > 0:
        error(presenceErr)
        return ord(ecError)
      if exists:
        devicesToRemove.add(device)

  for device in devicesToRemove:
    let exitCode = execCmd("incus config device remove " &
      quoteShell(containerName) & " " & quoteShell(device))
    if exitCode != 0:
      error(fmt"Failed to remove device {device}")
      return exitCode
  
  var exitCode = execCmd(fmt"incus config device add {quoteShell(containerName)} ssh-proxy proxy " &
                         fmt"listen=tcp:0.0.0.0:{port} connect=tcp:127.0.0.1:22 bind=host")
  if exitCode != 0:
    error("Failed to add SSH proxy device")
    return exitCode
  
  let serviceBase = getServicePortBase(port)
  for i in 0 ..< ServicePortsCount:
    let servicePort = serviceBase + i
    exitCode = execCmd(fmt"incus config device add {quoteShell(containerName)} svc-proxy-{i} proxy " &
                       fmt"listen=tcp:0.0.0.0:{servicePort} connect=tcp:127.0.0.1:{servicePort} bind=host")
    if exitCode != 0:
      error(fmt"Failed to add service proxy device {i}")
      return exitCode
  
  result = 0

# --- Fast clone storage helper ---

proc getInstanceRootPool(containerName: string): tuple[pool: string, err: string] =
  ## Return the Incus storage pool used by the instance root disk.
  let queryPath = "/1.0/instances/" & containerName & "?recursion=1"
  let (output, exitCode) = execCmdEx("incus query " & quoteShell(queryPath) & " 2>/dev/null")
  if exitCode != 0:
    return ("", fmt"Unable to inspect source container storage for '{containerName}'")

  try:
    let data = parseJson(output)
    if data.kind != JObject or not data.hasKey("expanded_devices"):
      return ("", fmt"Unable to inspect root disk for '{containerName}'")
    let devices = data["expanded_devices"]
    if devices.kind != JObject or not devices.hasKey("root"):
      return ("", fmt"Unable to inspect root disk for '{containerName}'")
    let root = devices["root"]
    if root.kind != JObject or not root.hasKey("pool"):
      return ("", fmt"Unable to inspect root storage pool for '{containerName}'")
    let pool = root["pool"].getStr()
    if pool.len == 0:
      return ("", fmt"Unable to inspect root storage pool for '{containerName}'")
    return (pool, "")
  except CatchableError as e:
    return ("", "Unable to parse Incus instance metadata: " & e.msg)

proc getStorageDriver(pool: string): tuple[driver: string, err: string] =
  ## Return the Incus storage driver for a pool.
  let queryPath = "/1.0/storage-pools/" & pool
  let (output, exitCode) = execCmdEx("incus query " & quoteShell(queryPath) & " 2>/dev/null")
  if exitCode != 0:
    return ("", fmt"Unable to inspect Incus storage pool '{pool}'")

  try:
    let data = parseJson(output)
    if data.kind != JObject or not data.hasKey("driver"):
      return ("", fmt"Unable to inspect Incus storage driver for pool '{pool}'")
    let driver = data["driver"].getStr()
    if driver.len == 0:
      return ("", fmt"Unable to inspect Incus storage driver for pool '{pool}'")
    return (driver, "")
  except CatchableError as e:
    return ("", "Unable to parse Incus storage metadata: " & e.msg)

proc checkFastCloneStorage(sourceContainerName, sourceDisplay: string): tuple[ok: bool, err: string] =
  ## Fail fast on storage backends where Incus snapshot/container copies are deep copies.
  let (pool, poolErr) = getInstanceRootPool(sourceContainerName)
  if poolErr.len > 0:
    return (false, poolErr)

  let (driver, driverErr) = getStorageDriver(pool)
  if driverErr.len > 0:
    return (false, driverErr)

  if driver == "dir":
    return (false,
      fmt"Fast clone unavailable for '{sourceDisplay}': Incus pool '{pool}' uses driver 'dir', " &
      "which performs a full filesystem copy. Move the base container to a CoW pool " &
      "(btrfs, zfs, lvm, or ceph) and retry so ocdev create returns quickly.")

  return (true, "")

# --- Per-instance Herdr directory helpers ---

proc prepareHerdrDirectory(containerName: string, fresh: bool): tuple[path, err: string] =
  ## Create the private host directory for an instance. Fresh preparation
  ## removes any previous destination state; ensure-only preparation preserves it.
  let path = getInstanceHerdrDir(containerName)
  try:
    if fresh:
      if symlinkExists(path) or fileExists(path):
        removeFile(path)
      elif dirExists(path):
        removeDir(path)
    elif symlinkExists(path) or (fileExists(path) and not dirExists(path)):
      return (path, fmt"Herdr path exists but is not a directory: {path}")

    createDir(path)
    setFilePermissions(path, HerdrDirectoryPermissions)
    return (path, "")
  except OSError as e:
    return (path, fmt"Failed to prepare Herdr directory '{path}': {e.msg}")

proc freshHerdrDirectory(containerName: string): tuple[path, err: string] =
  return prepareHerdrDirectory(containerName, fresh = true)

proc ensureHerdrDirectory(containerName: string): tuple[path, err: string] =
  return prepareHerdrDirectory(containerName, fresh = false)

proc removeHerdrDirectory(containerName: string): string =
  ## Remove an instance's host-side Herdr state. Returns an error message on failure.
  let path = getInstanceHerdrDir(containerName)
  try:
    if symlinkExists(path) or fileExists(path):
      removeFile(path)
    elif dirExists(path):
      removeDir(path)
    return ""
  except OSError as e:
    return fmt"Failed to remove Herdr directory '{path}': {e.msg}"

# --- Container cleanup helper ---

type
  ContainerCleanup* = object
    ## Tracks whether a container needs cleanup on failure
    containerName: string
    needed: bool

proc initCleanup(containerName: string): ContainerCleanup =
  ## Initialize cleanup tracker for a container
  ContainerCleanup(containerName: containerName, needed: true)

proc run(c: var ContainerCleanup) =
  ## Delete a failed instance, removing host state only after deletion succeeds
  ## or Incus explicitly confirms that the instance is absent.
  if c.needed:
    warn("Cleaning up failed container...")
    let (_, deleteExit) = execCmdEx("incus delete --force " &
      quoteShell(c.containerName) & " 2>&1")

    var inspectExit = 0
    var inspectOutput = ""
    if deleteExit != 0:
      (inspectOutput, inspectExit) = execCmdEx("incus info " &
        quoteShell(c.containerName) & " 2>&1")

    if mayRemoveHerdrAfterCleanup(deleteExit, inspectExit, inspectOutput):
      let herdrErr = removeHerdrDirectory(c.containerName)
      if herdrErr.len > 0:
        warn(herdrErr)
    elif inspectExit == 0:
      warn(fmt"Failed to delete '{c.containerName}'; instance still exists, preserving its Herdr directory")
    else:
      warn(fmt"Failed to confirm deletion of '{c.containerName}'; preserving its Herdr directory: {inspectOutput.strip()}")

proc cancel(c: var ContainerCleanup) =
  ## Mark cleanup as no longer needed (success path)
  c.needed = false

# --- Port allocation helper ---

proc allocatePortSafe(): tuple[port: int, err: string] =
  ## Allocate port with lock and error handling
  ## Returns (port, "") on success or (0, errorMsg) on failure
  try:
    let port = withLock(exclusive = true) do -> int:
      allocatePort()
    return (port, "")
  except IOError as e:
    return (0, "Failed to allocate port: " & e.msg)
  except ValueError as e:
    return (0, e.msg)

# --- Post-create script helper ---

proc runPostCreateScript(containerName, name, scriptPath: string): bool =
  ## Push and run post-create script as dev user
  ## Returns true on success, false on failure (logs warnings)
  let pushExit = execCmd(fmt"incus file push {scriptPath} {containerName}/tmp/ocdev-post-create.sh")
  if pushExit != 0:
    warn("Failed to push post-create script")
    return false
  
  let chmodExit = execCmd(fmt"incus exec {containerName} -- chmod +x /tmp/ocdev-post-create.sh")
  if chmodExit != 0:
    warn("Failed to set script permissions")
    return false
  
  let exitCode = execCmd(fmt"incus exec {containerName} -- su - dev -c /tmp/ocdev-post-create.sh")
  if exitCode == 0:
    discard execCmd(fmt"incus exec {containerName} -- rm -f /tmp/ocdev-post-create.sh")
    return true
  else:
    warn("Post-create script failed (container kept for debugging)")
    warn("Script left at /tmp/ocdev-post-create.sh inside container")
    warn(fmt"Debug with: ocdev shell {name}")
    return false

# --- Proxy device helper ---

proc addProxyDevices(containerName: string, sshPort: int): int =
  ## Add SSH and service proxy devices to container
  ## Returns 0 on success, non-zero on failure
  var exitCode = execCmd(fmt"incus config device add {containerName} ssh-proxy proxy " &
                         fmt"listen=tcp:0.0.0.0:{sshPort} connect=tcp:127.0.0.1:22 bind=host")
  if exitCode != 0:
    error("Failed to add SSH proxy device")
    return exitCode
  
  let serviceBase = getServicePortBase(sshPort)
  for i in 0 ..< ServicePortsCount:
    let servicePort = serviceBase + i
    exitCode = execCmd(fmt"incus config device add {containerName} svc-proxy-{i} proxy " &
                       fmt"listen=tcp:0.0.0.0:{servicePort} connect=tcp:127.0.0.1:{servicePort} bind=host")
    if exitCode != 0:
      error(fmt"Failed to add service proxy device {i}")
      return exitCode
  
  result = 0

# --- Disk mount helper ---

proc addDiskMount(containerName, deviceName, sourcePath, targetPath: string,
                  readonly = false): int =
  ## Add a quoted host disk device to an instance.
  var command = "incus config device add " & quoteShell(containerName) & " " &
    quoteShell(deviceName) & " disk " & quoteShell("source=" & sourcePath) & " " &
    quoteShell("path=" & targetPath)
  if readonly:
    command.add(" readonly=true")
  command.add(" shift=true")
  execCmd(command)

proc ensureHerdrMount(containerName: string): int =
  ## Ensure the isolated Herdr mount exists with the exact expected definition.
  ## Existing devices with the right name but wrong type/source/path are replaced.
  let (herdrPath, herdrErr) = ensureHerdrDirectory(containerName)
  if herdrErr.len > 0:
    error(herdrErr)
    return ord(ecError)

  let (exists, presenceErr) = inspectDevicePresence(containerName, HerdrDeviceName)
  if presenceErr.len > 0:
    error(presenceErr)
    return ord(ecError)

  if exists:
    let (deviceType, typeErr) = getDeviceProperty(containerName, HerdrDeviceName, "type")
    if typeErr.len > 0:
      error(typeErr)
      return ord(ecError)
    let (sourcePath, sourceErr) = getDeviceProperty(containerName, HerdrDeviceName, "source")
    if sourceErr.len > 0:
      error(sourceErr)
      return ord(ecError)
    let (targetPath, pathErr) = getDeviceProperty(containerName, HerdrDeviceName, "path")
    if pathErr.len > 0:
      error(pathErr)
      return ord(ecError)

    if herdrDeviceMatches(deviceType, sourcePath, targetPath, herdrPath):
      return 0

    let removeExit = execCmd("incus config device remove " &
      quoteShell(containerName) & " " & quoteShell(HerdrDeviceName))
    if removeExit != 0:
      error("Failed to remove mismatched Herdr mount")
      return removeExit

  let exitCode = addDiskMount(containerName, HerdrDeviceName, herdrPath, HerdrContainerPath)
  if exitCode != 0:
    error("Failed to mount isolated Herdr configuration")
  return exitCode

proc replaceHerdrMount(containerName: string): int =
  ## A clone may inherit the source device; ensureHerdrMount validates/replaces it.
  return ensureHerdrMount(containerName)

proc addDiskMounts(containerName: string): int =
  ## Add host directory disk mounts to container
  ## Returns 0 on success, non-zero on failure
  let homeDir = getHomeDir()

  if dirExists(homeDir / ".config"):
    let exitCode = addDiskMount(containerName, "host-config", homeDir / ".config", "/home/dev/.config")
    if exitCode != 0:
      error("Failed to mount ~/.config")
      return exitCode

  let herdrExit = ensureHerdrMount(containerName)
  if herdrExit != 0:
    return herdrExit

  if dirExists(homeDir / ".opencode"):
    let exitCode = addDiskMount(containerName, "host-opencode", homeDir / ".opencode", "/home/dev/.opencode")
    if exitCode != 0:
      error("Failed to mount ~/.opencode")
      return exitCode

  if dirExists(homeDir / ".claude"):
    let exitCode = addDiskMount(containerName, "host-claude", homeDir / ".claude", "/home/dev/.claude")
    if exitCode != 0:
      error("Failed to mount ~/.claude")
      return exitCode

  if dirExists(homeDir / ".codex"):
    let exitCode = addDiskMount(containerName, "host-codex", homeDir / ".codex", "/home/dev/.codex")
    if exitCode != 0:
      error("Failed to mount ~/.codex")
      return exitCode

  if dirExists(homeDir / ".omp"):
    let exitCode = addDiskMount(containerName, "host-omp", homeDir / ".omp", "/home/dev/.omp")
    if exitCode != 0:
      error("Failed to mount ~/.omp")
      return exitCode

  if dirExists(homeDir / ".ssh"):
    let exitCode = addDiskMount(containerName, "host-ssh", homeDir / ".ssh", "/home/dev/.ssh", readonly = true)
    if exitCode != 0:
      error("Failed to mount ~/.ssh")
      return exitCode

  if fileExists(homeDir / ".gitconfig"):
    let exitCode = addDiskMount(containerName, "host-gitconfig", homeDir / ".gitconfig", "/home/dev/.gitconfig", readonly = true)
    if exitCode != 0:
      error("Failed to mount ~/.gitconfig")
      return exitCode

  if dirExists(homeDir / ".local" / "share" / "opencode"):
    let exitCode = addDiskMount(containerName, "host-oc-share", homeDir / ".local" / "share" / "opencode", "/home/dev/.local/share/opencode")
    if exitCode != 0:
      error("Failed to mount ~/.local/share/opencode")
      return exitCode

  if dirExists(homeDir / ".local" / "state" / "opencode"):
    let exitCode = addDiskMount(containerName, "host-oc-state", homeDir / ".local" / "state" / "opencode", "/home/dev/.local/state/opencode")
    if exitCode != 0:
      error("Failed to mount ~/.local/state/opencode")
      return exitCode

  result = 0

proc addExpectedHostDiskDevice(containerName, deviceName: string): int =
  ## Recreate one standard host disk device after export.
  let homeDir = getHomeDir()
  case deviceName
  of HerdrDeviceName:
    return ensureHerdrMount(containerName)
  of "host-config":
    return addDiskMount(containerName, deviceName, homeDir / ".config", "/home/dev/.config")
  of "host-opencode":
    return addDiskMount(containerName, deviceName, homeDir / ".opencode", "/home/dev/.opencode")
  of "host-claude":
    return addDiskMount(containerName, deviceName, homeDir / ".claude", "/home/dev/.claude")
  of "host-codex":
    return addDiskMount(containerName, deviceName, homeDir / ".codex", "/home/dev/.codex")
  of "host-omp":
    return addDiskMount(containerName, deviceName, homeDir / ".omp", "/home/dev/.omp")
  of "host-ssh":
    return addDiskMount(containerName, deviceName, homeDir / ".ssh", "/home/dev/.ssh", readonly = true)
  of "host-gitconfig":
    return addDiskMount(containerName, deviceName, homeDir / ".gitconfig", "/home/dev/.gitconfig", readonly = true)
  of "host-oc-share":
    return addDiskMount(containerName, deviceName, homeDir / ".local" / "share" / "opencode", "/home/dev/.local/share/opencode")
  of "host-oc-state":
    return addDiskMount(containerName, deviceName, homeDir / ".local" / "state" / "opencode", "/home/dev/.local/state/opencode")
  else:
    return ord(ecError)

proc addExpectedProxyDevice(containerName, deviceName: string, sshPort: int): int =
  ## Recreate one standard proxy device after export.
  if sshPort <= 0:
    return ord(ecError)

  var listenPort, connectPort: int
  if deviceName == "ssh-proxy":
    listenPort = sshPort
    connectPort = 22
  elif deviceName.startsWith("svc-proxy-"):
    let indexText = deviceName["svc-proxy-".len .. ^1]
    let index = try: parseInt(indexText) except ValueError: -1
    if index < 0 or index >= ServicePortsCount:
      return ord(ecError)
    listenPort = getServicePortBase(sshPort) + index
    connectPort = listenPort
  else:
    return ord(ecError)

  return execCmd("incus config device add " & quoteShell(containerName) & " " &
    quoteShell(deviceName) & " proxy " & quoteShell("listen=tcp:0.0.0.0:" & $listenPort) &
    " " & quoteShell("connect=tcp:127.0.0.1:" & $connectPort) & " bind=host")

proc restoreExportDevice(containerName, deviceName: string, sshPort: int): string =
  ## Idempotently restore a device that was present before stripping. A failed
  ## removal may have left it in place, so inspect before attempting an add.
  if deviceName == HerdrDeviceName:
    if ensureHerdrMount(containerName) != 0:
      return fmt"Failed to restore device '{deviceName}'"
    return ""

  let (exists, inspectErr) = inspectDevicePresence(containerName, deviceName)
  if inspectErr.len > 0:
    return inspectErr
  if exists:
    return ""

  let restoreExit = if deviceName in HostDiskDeviceNames:
      addExpectedHostDiskDevice(containerName, deviceName)
    else:
      addExpectedProxyDevice(containerName, deviceName, sshPort)
  if restoreExit != 0:
    return fmt"Failed to restore device '{deviceName}'"
  return ""

proc checkPrerequisites(): int =
  ## Check incus command and group membership
  let (_, exitCode) = execCmdEx("command -v incus")
  if exitCode != 0:
    error("incus not found. Please install Incus.")
    return ord(ecPrereq)
  
  let (groups, _) = execCmdEx("groups")
  if "incus-admin" notin groups:
    error("User not in incus-admin group.")
    return ord(ecPrereq)
  
  # Ensure ocdev directory
  createDir(OcdevDir)
  if not fileExists(PortsFile):
    writeFile(PortsFile, "")
  
  result = ord(ecSuccess)

proc cmdCreate*(name: string, postCreate = "", fromSnapshot = "", `from` = ""): int =
  ## Create a new development container
  ## 
  ## Creates an Incus container with:
  ## - SSH access on allocated port (2200, 2210, 2220, ...)
  ## - Service ports (10 ports starting at corresponding 2300+)
  ## - Host directory mounts (~/.config, ~/.opencode, ~/.claude, ~/.codex, ~/.omp, ~/.ssh, ~/.gitconfig)
  ## - Docker-in-container support
  ## - Dev user with matching UID and passwordless sudo
  
  # Check prerequisites
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  # Validate name
  let (valid, msg) = validateName(name)
  if not valid:
    error("Invalid name: " & msg)
    return ord(ecError)
  
  # Check post-create script if provided
  if postCreate.len > 0:
    if not fileExists(postCreate):
      error("Post-create script not found: " & postCreate)
      return ord(ecError)
    let perms = getFilePermissions(postCreate)
    if fpUserRead notin perms:
      error("Post-create script not readable: " & postCreate)
      return ord(ecError)
  
  let containerName = ContainerPrefix & name
  let cloneArg = if fromSnapshot.len > 0: fromSnapshot else: `from`

  if fromSnapshot.len > 0 and `from`.len > 0:
    error("Use either --from-snapshot/--fromSnapshot or --from, not both")
    return ord(ecError)
  
  if cloneArg.len > 0:
    let (cloneSource, cloneValid, cloneErr) = parseCloneSource(cloneArg)
    if not cloneValid:
      error(cloneErr)
      return ord(ecError)

    if fromSnapshot.len > 0 and cloneSource.kind != cskSnapshot:
      error("Invalid snapshot format. Use container/snapshot (e.g., mycontainer/initial)")
      return ord(ecError)

    if not containerExists(cloneSource.container):
      error(fmt"Source container '{cloneSource.container}' not found")
      return ord(ecNotFound)

    if cloneSource.kind == cskSnapshot:
      if not snapshotExists(cloneSource.container, cloneSource.snapshot):
        error(fmt"Snapshot '{cloneSource.snapshot}' not found on container '{cloneSource.container}'")
        return ord(ecNotFound)
    elif containerRunning(cloneSource.container):
      warn("Source container is running. Clone will proceed while the source stays running, but in-flight filesystem changes may not be fully consistent.")

    # Confirm absence before resetting any preserved destination Herdr state.
    let (destinationAbsent, destinationErr) = inspectInstanceAbsent(containerName)
    if destinationErr.len > 0:
      error(destinationErr)
      return ord(ecError)
    if not destinationAbsent:
      error("Container '" & name & "' already exists")
      return ord(ecError)

    let sourceFullName = ContainerPrefix & cloneSource.container
    let sourceRef = if cloneSource.kind == cskSnapshot: sourceFullName & "/" & cloneSource.snapshot else: sourceFullName
    let sourceDisplay = if cloneSource.kind == cskSnapshot: cloneSource.container & "/" & cloneSource.snapshot else: cloneSource.container
    let (fastCloneOk, fastCloneErr) = checkFastCloneStorage(sourceFullName, sourceDisplay)
    if not fastCloneOk:
      error(fastCloneErr)
      return ord(ecError)

    # Allocate port
    let (port, portErr) = allocatePortSafe()
    if portErr.len > 0:
      error(portErr)
      return ord(ecError)

    let (_, herdrErr) = freshHerdrDirectory(containerName)
    if herdrErr.len > 0:
      error(herdrErr)
      let cleanupErr = removeHerdrDirectory(containerName)
      if cleanupErr.len > 0:
        warn(cleanupErr)
      return ord(ecError)

    var cleanup = initCleanup(containerName)

    info(fmt"Cloning container from {sourceDisplay}...")

    var exitCode = execCmd("incus copy " & quoteShell(sourceRef) & " " & quoteShell(containerName))
    if exitCode != 0:
      let cloneFailure = if cloneSource.kind == cskSnapshot: "Failed to clone from snapshot" else: "Failed to clone from container"
      error(cloneFailure)
      cleanup.run()
      return ord(ecError)

    # Clones inherit local devices, so replace the source Herdr mount before start.
    exitCode = replaceHerdrMount(containerName)
    if exitCode != 0:
      cleanup.run()
      return ord(ecError)

    # Reconfigure proxy devices with new ports
    info(fmt"Configuring ports (SSH: {port})...")
    exitCode = reconfigureProxyDevices(containerName, port)
    if exitCode != 0:
      cleanup.run()
      return ord(ecError)

    # Start container
    info("Starting container...")
    exitCode = execCmd("incus start " & quoteShell(containerName))
    if exitCode != 0:
      error("Failed to start container")
      cleanup.run()
      return ord(ecError)

    # Run custom post-create script if provided
    if postCreate.len > 0:
      info("Running post-create script...")
      discard runPostCreateScript(containerName, name, postCreate)

    # Success - save port allocation
    withLockVoid(exclusive = true) do ():
      savePortAllocation(name, port)

    cleanup.cancel()

    let serviceBase = getServicePortBase(port)
    let serviceEnd = serviceBase + ServicePortsCount - 1
    success(fmt"Container '{name}' created from {sourceDisplay} (SSH: {port}, Services: {serviceBase}-{serviceEnd})")
    return ord(ecSuccess)
  
  # Confirm absence before resetting any preserved destination Herdr state.
  let (destinationAbsent, destinationErr) = inspectInstanceAbsent(containerName)
  if destinationErr.len > 0:
    error(destinationErr)
    return ord(ecError)
  if not destinationAbsent:
    error("Container '" & name & "' already exists")
    return ord(ecError)
  
  # Ensure profile exists
  ensureProfile()
  
  # Allocate port
  let (port, portErr) = allocatePortSafe()
  if portErr.len > 0:
    error(portErr)
    return ord(ecError)
  
  let (_, herdrErr) = freshHerdrDirectory(containerName)
  if herdrErr.len > 0:
    error(herdrErr)
    let cleanupErr = removeHerdrDirectory(containerName)
    if cleanupErr.len > 0:
      warn(cleanupErr)
    return ord(ecError)

  var cleanup = initCleanup(containerName)
  
  info(fmt"Creating container '{name}' with SSH port {port}...")
  
  # Launch container
  var exitCode = execCmd("incus launch " & quoteShell(BaseImage) & " " & quoteShell(containerName) &
                         " --profile default --profile " & quoteShell(ProfileName))
  if exitCode != 0:
    error("Failed to launch container")
    cleanup.run()
    return ord(ecError)
  
  # Add proxy devices (SSH + service ports)
  let serviceBase = getServicePortBase(port)
  info(fmt"Configuring ports (SSH: {port}, Services: {serviceBase}-{serviceBase + ServicePortsCount - 1})...")
  exitCode = addProxyDevices(containerName, port)
  if exitCode != 0:
    cleanup.run()
    return ord(ecError)
  
  # Run provisioning script
  info("Provisioning container (this may take a few minutes)...")
  let hostUid = getuid().int
  let provisionScript = getProvisionScript(hostUid)
  
  # Write script to temp file, push to container, execute
  let tmpFile = getTempDir() / "ocdev-provision.sh"
  writeFile(tmpFile, provisionScript)
  defer: removeFile(tmpFile)
  
  let pushExit = execCmd(fmt"incus file push {tmpFile} {containerName}/tmp/provision.sh")
  if pushExit != 0:
    error("Failed to push provisioning script")
    cleanup.run()
    return ord(ecError)
  
  exitCode = execCmd(fmt"incus exec {containerName} -- bash /tmp/provision.sh")
  discard execCmd(fmt"incus exec {containerName} -- rm -f /tmp/provision.sh")
  
  if exitCode != 0:
    error("Provisioning failed")
    cleanup.run()
    return ord(ecError)

  # Run default post-install script as dev user
  info("Installing dev tools (uv, nvm, opencode)...")
  let postInstallTmp = getTempDir() / "ocdev-postinstall.sh"
  writeFile(postInstallTmp, PostInstallScript)
  defer: removeFile(postInstallTmp)
  
  let postInstallPush = execCmd(fmt"incus file push {postInstallTmp} {containerName}/tmp/postinstall.sh")
  if postInstallPush != 0:
    warn("Failed to push post-install script, skipping dev tools...")
  else:
    discard execCmd(fmt"incus exec {containerName} -- chmod +x /tmp/postinstall.sh")
    let postInstallExit = execCmd(fmt"incus exec {containerName} -- su - dev -c /tmp/postinstall.sh")
    discard execCmd(fmt"incus exec {containerName} -- rm -f /tmp/postinstall.sh")
    
    if postInstallExit != 0:
      warn("Default post-install completed with warnings (continuing...)")

  # Add disk devices after provisioning so host configs cannot affect installation.
  info("Configuring disk mounts...")
  exitCode = addDiskMounts(containerName)
  if exitCode != 0:
    cleanup.run()
    return ord(ecError)
  
  # Run custom post-create script if provided
  if postCreate.len > 0:
    info("Running post-create script...")
    discard runPostCreateScript(containerName, name, postCreate)
  
  # Success - save port allocation
  withLockVoid(exclusive = true) do ():
    savePortAllocation(name, port)
  
  cleanup.cancel()
  
  let serviceEnd = serviceBase + ServicePortsCount - 1
  success(fmt"Container '{name}' created (SSH: {port}, Services: {serviceBase}-{serviceEnd})")
  result = ord(ecSuccess)

proc cmdList*(): int =
  ## List all ocdev containers with status and SSH port
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  let (output, exitCode) = execCmdEx("incus list --format=csv -c n,s " & ContainerPrefix & " 2>&1")
  
  if exitCode != 0 and "No container" notin output:
    error("Failed to list containers: " & output)
    return ord(ecError)
  
  echo "NAME".alignLeft(20) & " " & "STATUS".alignLeft(10) & " SSH PORT"
  
  for line in output.strip().splitLines():
    if line.len == 0:
      continue
    let parts = line.split(',')
    if parts.len >= 2:
      let containerName = parts[0]
      let status = parts[1]
      let name = containerName.replace(ContainerPrefix, "")
      let port = getPort(name)
      let portStr = if port > 0: $port else: "N/A"
      echo name.alignLeft(20) & " " & status.alignLeft(10) & " " & portStr
  
  result = ord(ecSuccess)

proc cmdStart*(name: string): int =
  ## Start a stopped container
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  if containerRunning(name):
    info(fmt"Container '{name}' is already running")
    return ord(ecSuccess)
  
  let containerName = ContainerPrefix & name
  let herdrExit = ensureHerdrMount(containerName)
  if herdrExit != 0:
    return ord(ecError)

  let exitCode = execCmd("incus start " & quoteShell(containerName))
  if exitCode != 0:
    error("Failed to start container")
    return ord(ecError)
  
  success(fmt"Container '{name}' started")
  result = ord(ecSuccess)

proc cmdStop*(name: string): int =
  ## Stop a running container
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  if not containerRunning(name):
    info(fmt"Container '{name}' is already stopped")
    return ord(ecSuccess)
  
  let containerName = ContainerPrefix & name
  let exitCode = execCmd("incus stop " & containerName)
  if exitCode != 0:
    error("Failed to stop container")
    return ord(ecError)
  
  success(fmt"Container '{name}' stopped")
  result = ord(ecSuccess)

proc cmdShell*(name: string): int =
  ## Open interactive shell in container as dev user
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  if not containerRunning(name):
    error(fmt"Container '{name}' is not running. Use 'ocdev start {name}' first.")
    return ord(ecNotRunning)
  
  let containerName = ContainerPrefix & name
  # Use execCmd which inherits TTY for interactive shell
  result = execCmd("incus exec " & containerName & " -- su --login dev")

proc cmdSsh*(name: string): int =
  ## Display SSH connection info for container
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  let port = getPort(name)
  if port == 0:
    error(fmt"No SSH port found for '{name}'")
    return ord(ecError)
  
  let serviceBase = getServicePortBase(port)
  let serviceEnd = serviceBase + ServicePortsCount - 1
  
  echo "SSH:"
  echo fmt"  ssh -p {port} dev@localhost"
  echo ""
  echo "Service ports:"
  echo fmt"  {serviceBase}-{serviceEnd} -> container {serviceBase}-{serviceEnd}"
  echo ""
  echo "SSH config (~/.ssh/config):"
  echo ""
  echo fmt"Host {name}"
  echo "    HostName localhost"
  echo fmt"    Port {port}"
  echo "    User dev"
  
  result = ord(ecSuccess)

proc cmdDelete*(name: string): int =
  ## Delete a container and free its port allocation
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  let containerName = ContainerPrefix & name
  
  # Stop if running
  if containerRunning(name):
    info("Stopping container...")
    discard execCmd("incus stop " & quoteShell(containerName))
  
  # Delete container
  let exitCode = execCmd("incus delete " & quoteShell(containerName))
  if exitCode != 0:
    error("Failed to delete container")
    return ord(ecError)
  
  # Remove port allocation and per-instance host state
  removePort(name)
  let herdrErr = removeHerdrDirectory(containerName)
  if herdrErr.len > 0:
    error(herdrErr)
    return ord(ecError)
  
  success(fmt"Container '{name}' deleted")
  result = ord(ecSuccess)

proc cmdPorts*(): int =
  ## List all port allocations with container status
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  echo "NAME".alignLeft(20) & " " & "SSH".alignLeft(8) & " " & "SERVICES".alignLeft(15) & " STATUS"
  
  # Use shared lock for consistent read
  withLockVoid(exclusive = false) do ():
    if not fileExists(PortsFile):
      return
    
    for line in lines(PortsFile):
      let parts = line.strip().split(':')
      if parts.len < 2:
        continue
      
      let name = parts[0]
      let port = try: parseInt(parts[1]) except ValueError: 0
      if port == 0:
        continue
      
      var status: string
      
      if not containerExists(name):
        status = "DELETED"
      elif containerRunning(name):
        status = "RUNNING"
      else:
        status = "STOPPED"
      
      let serviceBase = getServicePortBase(port)
      let serviceEnd = serviceBase + ServicePortsCount - 1
      let services = fmt"{serviceBase}-{serviceEnd}"
      
      echo name.alignLeft(20) & " " & ($port).alignLeft(8) & " " & services.alignLeft(15) & " " & status
  
  result = ord(ecSuccess)

proc cmdBind*(name: string, port = "", list = false): int =
  ## Bind a container port to the host, or list current bindings
  ##
  ## Examples:
  ##   ocdev bind myvm 5173           # Bind host:5173 -> container:5173
  ##   ocdev bind myvm 3000:8080      # Bind host:8080 -> container:3000
  ##   ocdev bind myvm --list         # List current dynamic bindings
  
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  let containerName = ContainerPrefix & name
  
  # List mode
  if list:
    let bindings = getDynamicBindings(containerName)
    if bindings.len == 0:
      info("No dynamic port bindings")
      return ord(ecSuccess)
    
    echo "HOST".alignLeft(10) & " CONTAINER"
    for binding in bindings:
      echo ($binding.hostPort).alignLeft(10) & " " & $binding.containerPort
    return ord(ecSuccess)
  
  # Bind mode - port argument required
  if port.len == 0:
    error("Port argument required (or use --list)")
    return ord(ecError)
  
  let (containerPort, hostPort, valid, errMsg) = parsePortArg(port)
  if not valid:
    error(errMsg)
    return ord(ecError)
  
  let deviceName = fmt"dyn-{hostPort}"
  
  # Check if already bound
  if deviceExists(containerName, deviceName):
    error(fmt"Port {hostPort} is already bound to this container")
    return ord(ecError)
  
  # Add proxy device
  let exitCode = execCmd(fmt"incus config device add {containerName} {deviceName} proxy " &
                         fmt"listen=tcp:0.0.0.0:{hostPort} connect=tcp:127.0.0.1:{containerPort} bind=host")
  if exitCode != 0:
    error(fmt"Failed to bind port {hostPort}")
    return ord(ecError)
  
  if containerPort == hostPort:
    success(fmt"Bound port {hostPort}")
  else:
    success(fmt"Bound host:{hostPort} -> container:{containerPort}")
  
  result = ord(ecSuccess)

proc cmdUnbind*(name: string, port: int): int =
  ## Remove a port binding from a container
  ##
  ## Examples:
  ##   ocdev unbind myvm 5173         # Remove binding on host port 5173
  
  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq
  
  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)
  
  # Validate port range
  if port < MinPort or port > MaxPort:
    error(fmt"Port must be between {MinPort} and {MaxPort}")
    return ord(ecError)
  
  let containerName = ContainerPrefix & name
  let deviceName = fmt"dyn-{port}"
  
  # Check if binding exists
  if not deviceExists(containerName, deviceName):
    error(fmt"Port {port} is not bound to this container")
    return ord(ecError)
  
  # Remove proxy device
  let exitCode = execCmd(fmt"incus config device remove {containerName} {deviceName}")
  if exitCode != 0:
    error(fmt"Failed to unbind port {port}")
    return ord(ecError)
  
  success(fmt"Unbound port {port}")
  result = ord(ecSuccess)

proc cmdRebind*(name: string, port: string): int =
  ## Rebind a port to a different container, unbinding from the current owner first
  ##
  ## If the port is already bound to another container, it will be unbound first.
  ## If the port is not bound anywhere, it will simply be bound to the target.
  ##
  ## Examples:
  ##   ocdev rebind myvm 5173           # Move binding of port 5173 to myvm
  ##   ocdev rebind myvm 3000:8080      # Move host:8080 -> container:3000 to myvm

  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq

  # Validate name before using in shell commands
  let (nameValid, nameMsg) = validateName(name)
  if not nameValid:
    error("Invalid name: " & nameMsg)
    return ord(ecError)

  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)

  let (containerPort, hostPort, valid, errMsg) = parsePortArg(port)
  if not valid:
    error(errMsg)
    return ord(ecError)

  let targetContainerName = ContainerPrefix & name
  let deviceName = fmt"dyn-{hostPort}"

  # Check if already bound to the target container
  if deviceExists(targetContainerName, deviceName):
    info(fmt"Port {hostPort} is already bound to '{name}'")
    return ord(ecSuccess)

  # Find which container currently has this port bound
  let currentOwner = findPortBinding(hostPort)

  if currentOwner.len > 0:
    # Unbind from current owner
    let shortName = currentOwner[ContainerPrefix.len..^1]
    info(fmt"Unbinding port {hostPort} from '{shortName}'")
    let unbindCode = execCmd(fmt"incus config device remove {currentOwner} {deviceName}")
    if unbindCode != 0:
      error(fmt"Failed to unbind port {hostPort} from '{shortName}'")
      return ord(ecError)

  # Bind to target container
  # NOTE: Listens on 0.0.0.0 (all interfaces) to match cmdBind behavior.
  # If the host is exposed to untrusted networks, consider restricting to 127.0.0.1.
  let exitCode = execCmd(fmt"incus config device add {targetContainerName} {deviceName} proxy " &
                         fmt"listen=tcp:0.0.0.0:{hostPort} connect=tcp:127.0.0.1:{containerPort} bind=host")
  if exitCode != 0:
    error(fmt"Failed to bind port {hostPort} to '{name}'")
    return ord(ecError)

  if currentOwner.len > 0:
    let shortName = currentOwner[ContainerPrefix.len..^1]
    if containerPort == hostPort:
      success(fmt"Rebound port {hostPort} from '{shortName}' to '{name}'")
    else:
      success(fmt"Rebound host:{hostPort} -> container:{containerPort} from '{shortName}' to '{name}'")
  else:
    if containerPort == hostPort:
      success(fmt"Bound port {hostPort} to '{name}'")
    else:
      success(fmt"Bound host:{hostPort} -> container:{containerPort} to '{name}'")

  result = ord(ecSuccess)

proc cmdExport*(name: string, output = ""): int =
  ## Export a container as a portable tarball. Running instances are stopped
  ## before any nested host mount is removed and restarted after restoration.
  ##
  ## Examples:
  ##   ocdev export myvm
  ##   ocdev export myvm --output /tmp/myvm.tar.gz

  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq

  let (valid, msg) = validateName(name)
  if not valid:
    error("Invalid name: " & msg)
    return ord(ecError)

  if not containerExists(name):
    error(fmt"Container '{name}' not found")
    return ord(ecNotFound)

  let containerName = ContainerPrefix & name
  let (wasRunning, stateErr) = inspectInstanceRunning(containerName)
  if stateErr.len > 0:
    error(stateErr)
    return ord(ecError)

  if wasRunning:
    info("Stopping container before removing host mounts...")
    if execCmd("incus stop " & quoteShell(containerName)) != 0:
      error("Failed to stop container; export aborted before stripping devices")
      return ord(ecError)

  let outputPath = if output.len > 0: output
                   else: getCurrentDir() / fmt"{name}.tar.gz"
  var proxyDevices = @["ssh-proxy"]
  for i in 0 ..< ServicePortsCount:
    proxyDevices.add("svc-proxy-" & $i)

  var originalDevices: seq[string] = @[]
  var operationFailure = ""
  var exportExit = ord(ecError)
  var restorationFailures: seq[string] = @[]
  var restartFailure = ""

  try:
    let (deviceNames, inspectErr) = inspectDeviceNames(containerName)
    if inspectErr.len > 0:
      operationFailure = inspectErr
    else:
      for device in HostDiskDeviceNames:
        if device in deviceNames:
          originalDevices.add(device)
      for device in proxyDevices:
        if device in deviceNames:
          originalDevices.add(device)

      info("Stripping host-specific devices before export...")
      for device in originalDevices:
        let removeExit = execCmd("incus config device remove " &
          quoteShell(containerName) & " " & quoteShell(device))
        if removeExit != 0:
          operationFailure = fmt"Failed to remove device '{device}'; export aborted"
          error(operationFailure)
          break

      if operationFailure.len == 0:
        info(fmt"Exporting container '{name}'...")
        exportExit = execCmd("incus export " & quoteShell(containerName) & " " &
          quoteShell(outputPath) & " --instance-only")
  except CatchableError as e:
    operationFailure = "Unexpected export failure: " & e.msg
  finally:
    info("Restoring host-specific devices...")
    var port = 0
    try:
      port = getPort(name)
    except CatchableError as e:
      let portErr = "Failed to read port allocation during device restoration: " & e.msg
      restorationFailures.add(portErr)
      error(portErr)

    var restoreOrder: seq[string] = @[]
    # Restore the parent ~/.config mount before its nested Herdr mount.
    for device in HostDiskDeviceNames:
      if device != HerdrDeviceName and device in originalDevices:
        restoreOrder.add(device)
    if HerdrDeviceName in originalDevices:
      restoreOrder.add(HerdrDeviceName)
    for device in proxyDevices:
      if device in originalDevices:
        restoreOrder.add(device)

    for device in restoreOrder:
      var restoreErr = ""
      try:
        restoreErr = restoreExportDevice(containerName, device, port)
      except CatchableError as e:
        restoreErr = fmt"Failed to restore device '{device}': {e.msg}"
      if restoreErr.len > 0:
        restorationFailures.add(restoreErr)
        error(restoreErr)

    # Legacy instances might not have had host-herdr before export. Never restart
    # without validating or adding the isolated nested mount.
    if ensureHerdrMount(containerName) != 0:
      let herdrErr = "Failed to ensure isolated Herdr mount after export"
      restorationFailures.add(herdrErr)
      error(herdrErr)

    if mayRestartAfterExport(wasRunning, restorationFailures.len):
      info("Restarting container...")
      try:
        if execCmd("incus start " & quoteShell(containerName)) != 0:
          restartFailure = fmt"Failed to restart container '{name}' after export restoration"
      except CatchableError as e:
        restartFailure = fmt"Failed to restart container '{name}' after export restoration: {e.msg}"
      if restartFailure.len > 0:
        error(restartFailure)
    elif wasRunning and restorationFailures.len > 0:
      restartFailure = fmt"Container '{name}' was left stopped because host-specific device restoration failed"
      error(restartFailure)

  var failed = false
  if operationFailure.len > 0:
    if not operationFailure.startsWith("Failed to remove device"):
      error(operationFailure)
    failed = true
  elif exportExit != 0:
    error("Failed to export container")
    failed = true
  if restorationFailures.len > 0:
    error(fmt"Failed to restore {restorationFailures.len} host-specific device(s)")
    failed = true
  if restartFailure.len > 0:
    failed = true
  if failed:
    return ord(ecError)

  success(fmt"Exported '{name}' to {outputPath}")
  info("Transfer this file to another server and use 'ocdev import' to restore.")
  result = ord(ecSuccess)

proc cmdImport*(name: string, file: string): int =
  ## Import a container from an exported tarball
  ##
  ## Imports the tarball using 'incus import' which preserves the full
  ## container filesystem. Then reconfigures ports and disk mounts for
  ## the new host.
  ##
  ## Examples:
  ##   ocdev import myvm --file /tmp/myvm.tar.gz

  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq

  # Validate name
  let (valid, msg) = validateName(name)
  if not valid:
    error("Invalid name: " & msg)
    return ord(ecError)

  # Check file exists
  if not fileExists(file):
    error(fmt"File not found: {file}")
    return ord(ecError)

  let containerName = ContainerPrefix & name

  # Confirm absence before resetting any preserved destination Herdr state.
  let (destinationAbsent, destinationErr) = inspectInstanceAbsent(containerName)
  if destinationErr.len > 0:
    error(destinationErr)
    return ord(ecError)
  if not destinationAbsent:
    error("Container '" & name & "' already exists")
    return ord(ecError)

  # Ensure profile exists
  ensureProfile()

  # Allocate port
  let (port, portErr) = allocatePortSafe()
  if portErr.len > 0:
    error(portErr)
    return ord(ecError)

  let (_, herdrErr) = freshHerdrDirectory(containerName)
  if herdrErr.len > 0:
    error(herdrErr)
    let cleanupErr = removeHerdrDirectory(containerName)
    if cleanupErr.len > 0:
      warn(cleanupErr)
    return ord(ecError)

  var cleanup = initCleanup(containerName)

  # Import container from backup tarball
  info(fmt"Importing container from {file}...")
  var exitCode = execCmd("incus import " & quoteShell(file) & " " & quoteShell(containerName))
  if exitCode != 0:
    error("Failed to import container from file")
    cleanup.run()
    return ord(ecError)

  # Reconfigure proxy devices with fresh ports (remove old, add new).
  # Any inherited-device removal failure is fatal; adding directly could hide it.
  info(fmt"Configuring ports (SSH: {port})...")
  exitCode = reconfigureProxyDevices(containerName, port)
  if exitCode != 0:
    cleanup.run()
    return ord(ecError)

  # Remove inherited disk mounts (source paths won't match on new host)
  # and add fresh ones pointing to the current host's home directory.
  info("Configuring disk mounts...")
  let (importDeviceNames, inspectErr) = inspectDeviceNames(containerName)
  if inspectErr.len > 0:
    error(inspectErr)
    cleanup.run()
    return ord(ecError)
  for device in HostDiskDeviceNames:
    if device in importDeviceNames:
      let removeExit = execCmd("incus config device remove " &
        quoteShell(containerName) & " " & quoteShell(device))
      if removeExit != 0:
        error(fmt"Failed to remove inherited device '{device}'")
        cleanup.run()
        return ord(ecError)

  exitCode = addDiskMounts(containerName)
  if exitCode != 0:
    cleanup.run()
    return ord(ecError)

  # Clear volatile config (MAC address, etc.) to avoid conflicts on new host
  discard execCmd("incus config unset " & quoteShell(containerName) & " volatile.eth0.hwaddr")
  discard execCmd("incus config unset " & quoteShell(containerName) & " volatile.eth0.host_name")

  # Start container
  info("Starting container...")
  exitCode = execCmd("incus start " & quoteShell(containerName))
  if exitCode != 0:
    error("Failed to start container")
    cleanup.run()
    return ord(ecError)

  # Save port allocation
  withLockVoid(exclusive = true) do ():
    savePortAllocation(name, port)

  cleanup.cancel()

  let serviceBase = getServicePortBase(port)
  let serviceEnd = serviceBase + ServicePortsCount - 1
  success(fmt"Container '{name}' imported (SSH: {port}, Services: {serviceBase}-{serviceEnd})")
  result = ord(ecSuccess)

proc cmdBindings*(): int =
  ## List all dynamic port bindings across all containers
  ##
  ## Examples:
  ##   ocdev bindings

  let prereq = checkPrerequisites()
  if prereq != 0:
    return prereq

  # Fetch container names and status in a single call to avoid N+1 subprocess calls
  let (output, exitCode) = execCmdEx("incus list --format csv -c n,s")
  if exitCode != 0:
    error("Failed to list containers")
    return ord(ecError)

  var found = false

  for line in output.strip().splitLines():
    let parts = line.strip().split(',')
    if parts.len < 2:
      continue
    let containerName = parts[0]
    let status = parts[1]
    if not containerName.startsWith(ContainerPrefix):
      continue

    let bindings = getDynamicBindings(containerName)
    if bindings.len == 0:
      continue

    if not found:
      echo "CONTAINER".alignLeft(20) & " " & "HOST".alignLeft(10) & " " & "CONTAINER".alignLeft(14) & " STATUS"
      found = true

    let shortName = containerName[ContainerPrefix.len..^1]

    for binding in bindings:
      echo shortName.alignLeft(20) & " " & ($binding.hostPort).alignLeft(10) & " " &
           ($binding.containerPort).alignLeft(14) & " " & status

  if not found:
    info("No dynamic port bindings")

  result = ord(ecSuccess)
