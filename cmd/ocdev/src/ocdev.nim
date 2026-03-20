## ocdev - Manage isolated development environments using Incus containers
import cligen
import config, commands

# Set version for --version flag
clCfg.version = Version

# Clean up help output
clCfg.noHelpHelp = true                            # Remove --help-syntax row
clCfg.minStrQuoting = true                          # Blank instead of "" for empty defaults
clCfg.hTabCols = @[clOptKeys, clDflVal, clDescrip]  # Drop type column

# Cleaner top-level help template
clCfg.useMulti = """${doc}Usage:
  $command {SUBCMD}  [sub-command options & parameters]

Subcommands:
$subcmds
Run "$command SUBCMD --help" for details on a specific command.${ifVersion}"""

when isMainModule:
  const noVer = "CLIGEN-NOHELP" # Hide --version from subcommand help tables

  dispatchMulti(
    [cmdCreate, cmdName = "create",
     doc = "Create a new development container",
    short = {"name": 'n', "postCreate": '\0', "from": '\0', "version": '\0'},
    help = {
      "version": noVer,
      "name": "Container name (alphanumeric and hyphens, max 50 chars)",
      "postCreate": "Script to run after container creation",
      "from": "Create from existing container or snapshot (format: container or container/snapshot)"
     }],
    [cmdList, cmdName = "list",
     doc = "List all ocdev containers",
     short = {"version": '\0'},
     help = {"version": noVer}],
    [cmdStart, cmdName = "start",
     doc = "Start a stopped container",
     short = {"name": 'n', "version": '\0'},
     help = {"version": noVer, "name": "Container name"}],
    [cmdStop, cmdName = "stop",
     doc = "Stop a running container",
     short = {"name": 'n', "version": '\0'},
     help = {"version": noVer, "name": "Container name"}],
    [cmdShell, cmdName = "shell",
     doc = "Open interactive shell in container",
     short = {"name": 'n', "version": '\0'},
     help = {"version": noVer, "name": "Container name"}],
    [cmdSsh, cmdName = "ssh",
     doc = "Display SSH connection info",
     short = {"name": 'n', "version": '\0'},
     help = {"version": noVer, "name": "Container name"}],
    [cmdDelete, cmdName = "delete",
     doc = "Delete a container",
     short = {"name": 'n', "version": '\0'},
     help = {"version": noVer, "name": "Container name"}],
    [cmdPorts, cmdName = "ports",
     doc = "List all port allocations",
     short = {"version": '\0'},
     help = {"version": noVer}],
    [cmdBind, cmdName = "bind",
     doc = "Bind a container port to the host",
     short = {"name": 'n', "port": 'p', "list": '\0', "version": '\0'},
     help = {
       "version": noVer,
       "name": "Container name",
       "port": "Port to bind (PORT or CONTAINER_PORT:HOST_PORT)",
       "list": "List current dynamic port bindings"
     }],
    [cmdUnbind, cmdName = "unbind",
     doc = "Remove a port binding",
     short = {"name": 'n', "port": 'p', "version": '\0'},
     help = {
       "version": noVer,
       "name": "Container name",
       "port": "Host port to unbind"
     }],
    [cmdRebind, cmdName = "rebind",
     doc = "Move a port binding to a different container",
     short = {"name": 'n', "port": 'p', "version": '\0'},
     help = {
       "version": noVer,
       "name": "Target container name",
       "port": "Port to rebind (PORT or CONTAINER_PORT:HOST_PORT)"
     }],
    [cmdBindings, cmdName = "bindings",
     doc = "List all dynamic port bindings across containers",
     short = {"version": '\0'},
     help = {"version": noVer}],
    [cmdExport, cmdName = "export",
     doc = "Export a container as a portable tarball",
     short = {"name": 'n', "output": 'o', "version": '\0'},
     help = {
       "version": noVer,
       "name": "Container name (stopping first recommended)",
       "output": "Output file path (default: ./<name>.tar.gz)"
     }],
    [cmdImport, cmdName = "import",
     doc = "Import a container from an exported tarball",
     short = {"name": 'n', "file": 'f', "version": '\0'},
     help = {
       "version": noVer,
       "name": "Name for the new container",
       "file": "Path to the exported tarball"
     }]
  )
