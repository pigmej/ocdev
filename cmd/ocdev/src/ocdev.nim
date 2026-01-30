## ocdev - Manage isolated development environments using Incus containers
import cligen
import config, commands

# Set version for --version flag
clCfg.version = Version

when isMainModule:
  dispatchMulti(
    [cmdCreate, cmdName = "create", 
     doc = "Create a new development container",
     help = {
       "name": "Container name (alphanumeric and hyphens, max 50 chars)",
       "postCreate": "Script to run after container creation",
       "fromSnapshot": "Create from snapshot (format: container/snapshot)"
     }],
    [cmdList, cmdName = "list",
     doc = "List all ocdev containers"],
    [cmdStart, cmdName = "start",
     doc = "Start a stopped container",
     help = {"name": "Container name"}],
    [cmdStop, cmdName = "stop",
     doc = "Stop a running container",
     help = {"name": "Container name"}],
    [cmdShell, cmdName = "shell",
     doc = "Open interactive shell in container",
     help = {"name": "Container name"}],
    [cmdSsh, cmdName = "ssh",
     doc = "Display SSH connection info",
     help = {"name": "Container name"}],
    [cmdDelete, cmdName = "delete",
     doc = "Delete a container",
     help = {"name": "Container name"}],
    [cmdPorts, cmdName = "ports",
     doc = "List all port allocations"],
    [cmdBind, cmdName = "bind",
     doc = "Bind a container port to the host",
     help = {
       "name": "Container name",
       "port": "Port to bind (PORT or CONTAINER_PORT:HOST_PORT)",
       "list": "List current dynamic port bindings"
     }],
    [cmdUnbind, cmdName = "unbind",
      doc = "Remove a port binding",
      help = {
        "name": "Container name",
        "port": "Host port to unbind"
      }],
    [cmdRebind, cmdName = "rebind",
      doc = "Move a port binding to a different container",
      help = {
        "name": "Target container name",
        "port": "Port to rebind (PORT or CONTAINER_PORT:HOST_PORT)"
      }],
    [cmdBindings, cmdName = "bindings",
      doc = "List all dynamic port bindings across containers"]
  )
