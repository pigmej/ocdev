## Command implementations for ocdev
import std/[os, osproc, strutils, strformat, posix]
import config, output, container, ports, profile, provision

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

proc cmdCreate*(name: string, postCreate = ""): int =
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
  
  # Check container doesn't already exist
  if containerExists(name):
    error("Container '" & name & "' already exists")
    return ord(ecError)
  
  # Ensure profile exists
  ensureProfile()
  
  # Allocate port with lock
  var port: int
  try:
    port = withLock(exclusive = true) do -> int:
      allocatePort()
  except IOError as e:
    error("Failed to allocate port: " & e.msg)
    return ord(ecError)
  except ValueError as e:
    error(e.msg)
    return ord(ecError)
  
  # Cleanup function for failure - track if cleanup is needed
  var cleanupNeeded = true
  
  proc doCleanup() =
    if cleanupNeeded:
      warn("Cleaning up failed container...")
      discard execCmd("incus delete --force " & containerName & " 2>/dev/null")
  
  info(fmt"Creating container '{name}' with SSH port {port}...")
  
  # Launch container
  var exitCode = execCmd("incus launch " & BaseImage & " " & containerName & 
                         " --profile default --profile " & ProfileName)
  if exitCode != 0:
    error("Failed to launch container")
    doCleanup()
    return ord(ecError)
  
  # Add disk devices
  info("Configuring disk mounts...")
  
  let homeDir = getHomeDir()
  
  if dirExists(homeDir / ".config"):
    discard execCmd(fmt"incus config device add {containerName} host-config disk " &
                   fmt"source={homeDir}/.config path=/home/dev/.config shift=true")
  
  if dirExists(homeDir / ".opencode"):
    discard execCmd(fmt"incus config device add {containerName} host-opencode disk " &
                   fmt"source={homeDir}/.opencode path=/home/dev/.opencode shift=true")
  
  if dirExists(homeDir / ".ssh"):
    discard execCmd(fmt"incus config device add {containerName} host-ssh disk " &
                   fmt"source={homeDir}/.ssh path=/home/dev/.ssh readonly=true shift=true")
  
  if fileExists(homeDir / ".gitconfig"):
    discard execCmd(fmt"incus config device add {containerName} host-gitconfig disk " &
                   fmt"source={homeDir}/.gitconfig path=/home/dev/.gitconfig readonly=true shift=true")
  
  # Add SSH proxy device
  info(fmt"Configuring SSH proxy on port {port}...")
  discard execCmd(fmt"incus config device add {containerName} ssh-proxy proxy " &
                 fmt"listen=tcp:0.0.0.0:{port} connect=tcp:127.0.0.1:22 bind=host")
  
  # Add service port proxy devices
  let serviceBase = getServicePortBase(port)
  info(fmt"Configuring service ports {serviceBase}-{serviceBase + ServicePortsCount - 1}...")
  for i in 0 ..< ServicePortsCount:
    let servicePort = serviceBase + i
    discard execCmd(fmt"incus config device add {containerName} svc-proxy-{i} proxy " &
                   fmt"listen=tcp:0.0.0.0:{servicePort} connect=tcp:127.0.0.1:{servicePort} bind=host")
  
  # Run provisioning script
  info("Provisioning container (this may take a few minutes)...")
  let hostUid = getuid().int
  let provisionScript = getProvisionScript(hostUid)
  
  # Write script to temp file, push to container, execute
  let tmpFile = getTempDir() / "ocdev-provision.sh"
  writeFile(tmpFile, provisionScript)
  defer: removeFile(tmpFile)
  
  discard execCmd(fmt"incus file push {tmpFile} {containerName}/tmp/provision.sh")
  exitCode = execCmd(fmt"incus exec {containerName} -- bash /tmp/provision.sh")
  discard execCmd(fmt"incus exec {containerName} -- rm -f /tmp/provision.sh")
  
  if exitCode != 0:
    error("Provisioning failed")
    doCleanup()
    return ord(ecError)
  
  # Run custom post-create script if provided
  if postCreate.len > 0:
    info("Running post-create script...")
    discard execCmd(fmt"incus file push {postCreate} {containerName}/tmp/ocdev-post-create.sh")
    discard execCmd(fmt"incus exec {containerName} -- chmod +x /tmp/ocdev-post-create.sh")
    
    exitCode = execCmd(fmt"incus exec {containerName} -- su - dev -c /tmp/ocdev-post-create.sh")
    if exitCode == 0:
      discard execCmd(fmt"incus exec {containerName} -- rm -f /tmp/ocdev-post-create.sh")
    else:
      warn("Post-create script failed (container kept for debugging)")
      warn("Script left at /tmp/ocdev-post-create.sh inside container")
      warn(fmt"Debug with: ocdev shell {name}")
  
  # Success - save port allocation
  withLockVoid(exclusive = true) do ():
    savePortAllocation(name, port)
  
  cleanupNeeded = false
  
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
