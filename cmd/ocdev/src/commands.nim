## Command implementations for ocdev
import std/[os, osproc, strutils, strformat, posix]
import config, output, container, ports, profile, provision, postinstall

const
  MinPort = 1
  MaxPort = 65535

proc deviceExists(containerName, deviceName: string): bool =
  ## Check if a device exists on a container
  let (output, exitCode) = execCmdEx(fmt"incus config device list {containerName}")
  if exitCode != 0:
    return false
  for line in output.strip().splitLines():
    if line.strip() == deviceName:
      return true
  return false

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

proc reconfigureProxyDevices(containerName: string, port: int): int =
  ## Remove inherited proxy devices and add new ones with correct ports
  ## Also removes dynamic bindings (dyn-*) to avoid port conflicts with source container
  var standardDevices = @["ssh-proxy"]
  for i in 0 ..< ServicePortsCount:
    standardDevices.add("svc-proxy-" & $i)
  
  # Also remove dynamic bindings - they would conflict with source container
  let dynamicBindings = getDynamicBindings(containerName)
  for binding in dynamicBindings:
    standardDevices.add("dyn-" & $binding.hostPort)
  
  for device in standardDevices:
    if deviceExists(containerName, device):
      let exitCode = execCmd(fmt"incus config device remove {containerName} {device}")
      if exitCode != 0:
        error(fmt"Failed to remove device {device}")
        return exitCode
  
  var exitCode = execCmd(fmt"incus config device add {containerName} ssh-proxy proxy " &
                         fmt"listen=tcp:0.0.0.0:{port} connect=tcp:127.0.0.1:22 bind=host")
  if exitCode != 0:
    error("Failed to add SSH proxy device")
    return exitCode
  
  let serviceBase = getServicePortBase(port)
  for i in 0 ..< ServicePortsCount:
    let servicePort = serviceBase + i
    exitCode = execCmd(fmt"incus config device add {containerName} svc-proxy-{i} proxy " &
                       fmt"listen=tcp:0.0.0.0:{servicePort} connect=tcp:127.0.0.1:{servicePort} bind=host")
    if exitCode != 0:
      error(fmt"Failed to add service proxy device {i}")
      return exitCode
  
  result = 0

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
  ## Execute cleanup if needed (delete the container)
  if c.needed:
    warn("Cleaning up failed container...")
    discard execCmd("incus delete --force " & c.containerName & " 2>/dev/null")

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

proc addDiskMounts(containerName: string): int =
  ## Add host directory disk mounts to container
  ## Returns 0 on success, non-zero on failure
  let homeDir = getHomeDir()
  
  if dirExists(homeDir / ".config"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-config disk " &
                           fmt"source={homeDir}/.config path=/home/dev/.config shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.config")
      return exitCode
  
  if dirExists(homeDir / ".opencode"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-opencode disk " &
                           fmt"source={homeDir}/.opencode path=/home/dev/.opencode shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.opencode")
      return exitCode
  
  if dirExists(homeDir / ".ssh"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-ssh disk " &
                           fmt"source={homeDir}/.ssh path=/home/dev/.ssh readonly=true shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.ssh")
      return exitCode
  
  if fileExists(homeDir / ".gitconfig"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-gitconfig disk " &
                           fmt"source={homeDir}/.gitconfig path=/home/dev/.gitconfig readonly=true shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.gitconfig")
      return exitCode
  
  if dirExists(homeDir / ".local" / "share" / "opencode"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-oc-share disk " &
                           fmt"source={homeDir}/.local/share/opencode path=/home/dev/.local/share/opencode shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.local/share/opencode")
      return exitCode
  
  if dirExists(homeDir / ".local" / "state" / "opencode"):
    let exitCode = execCmd(fmt"incus config device add {containerName} host-oc-state disk " &
                           fmt"source={homeDir}/.local/state/opencode path=/home/dev/.local/state/opencode shift=true")
    if exitCode != 0:
      error("Failed to mount ~/.local/state/opencode")
      return exitCode
  
  result = 0

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

proc cmdCreate*(name: string, postCreate = "", fromSnapshot = ""): int =
  ## Create a new development container
  ## 
  ## Creates an Incus container with:
  ## - SSH access on allocated port (2200, 2210, 2220, ...)
  ## - Service ports (10 ports starting at corresponding 2300+)
  ## - Host directory mounts (~/.config, ~/.ssh, ~/.opencode, ~/.gitconfig)
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
  
  # Handle snapshot clone flow
  if fromSnapshot.len > 0:
    # Parse fromSnapshot (format: container/snapshot)
    let snapshotParts = fromSnapshot.split('/')
    if snapshotParts.len != 2:
      error("Invalid snapshot format. Use: container/snapshot")
      return ord(ecError)
    
    let sourceContainer = snapshotParts[0]
    let snapshotName = snapshotParts[1]
    
    # Validate source container exists
    if not containerExists(sourceContainer):
      error(fmt"Source container '{sourceContainer}' not found")
      return ord(ecNotFound)
    
    # Validate snapshot exists
    if not snapshotExists(sourceContainer, snapshotName):
      error(fmt"Snapshot '{snapshotName}' not found on container '{sourceContainer}'")
      return ord(ecNotFound)
    
    # Check destination doesn't exist
    if containerExists(name):
      error("Container '" & name & "' already exists")
      return ord(ecError)
    
    # Allocate port
    let (port, portErr) = allocatePortSafe()
    if portErr.len > 0:
      error(portErr)
      return ord(ecError)
    
    var cleanup = initCleanup(containerName)
    
    let sourceFullName = ContainerPrefix & sourceContainer
    info(fmt"Cloning container from {sourceContainer}/{snapshotName}...")
    
    # Clone from snapshot
    var exitCode = execCmd(fmt"incus copy {sourceFullName}/{snapshotName} {containerName}")
    if exitCode != 0:
      error("Failed to clone from snapshot")
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
    exitCode = execCmd(fmt"incus start {containerName}")
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
    success(fmt"Container '{name}' created from snapshot (SSH: {port}, Services: {serviceBase}-{serviceEnd})")
    return ord(ecSuccess)
  
  # Check container doesn't already exist
  if containerExists(name):
    error("Container '" & name & "' already exists")
    return ord(ecError)
  
  # Ensure profile exists
  ensureProfile()
  
  # Allocate port
  let (port, portErr) = allocatePortSafe()
  if portErr.len > 0:
    error(portErr)
    return ord(ecError)
  
  var cleanup = initCleanup(containerName)
  
  info(fmt"Creating container '{name}' with SSH port {port}...")
  
  # Launch container
  var exitCode = execCmd("incus launch " & BaseImage & " " & containerName & 
                         " --profile default --profile " & ProfileName)
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
  
  # Add disk devices (after provisioning so /home/dev is owned by dev user)
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
  let exitCode = execCmd("incus start " & containerName)
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
    discard execCmd("incus stop " & containerName)
  
  # Delete container
  let exitCode = execCmd("incus delete " & containerName)
  if exitCode != 0:
    error("Failed to delete container")
    return ord(ecError)
  
  # Remove port allocation
  removePort(name)
  
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
