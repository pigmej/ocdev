## CLI-only orchestration. Human output and JSON share the same operations.
import std/[os, json, strutils, tables, sequtils]
import cligen/parseopt3
import config, commands, ports, automation, recipes, recipe_engine, safe_input, exec_cli

type
  Options = object
    positional: seq[string]
    values: Table[string, string]

proc invalid(message = "arguments.invalid") {.noreturn.} =
  raise newException(ValueError, message)

proc parseOptions(args: seq[string]): Options =
  result.values = initTable[string, string]()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      if i + 1 < args.len: result.positional.add(args[i + 1 .. ^1])
      break
    if arg.startsWith('-'):
      let parts = arg.split('=', 1)
      var key = parts[0].strip(chars = {'-'})
      case key
      of "n": key = "name"
      of "p": key = "port"
      of "f": key = "file"
      of "o": key = "output"
      of "postCreate": key = "post-create"
      of "fromSnapshot": key = "from-snapshot"
      else: discard
      if result.values.hasKey(key): invalid("arguments.duplicate_option")
      if key == "fresh":
        var enabled = true
        if parts.len == 2:
          try: enabled = parseBool(parts[1])
          except ValueError: invalid("arguments.invalid_flag")
        result.values[key] = $enabled
      elif key in ["json", "dry-run", "rerun", "list", "help"]:
        if parts.len > 1: invalid("arguments.invalid_flag")
        result.values[key] = "true"
      else:
        if parts.len == 2:
          result.values[key] = parts[1]
        else:
          inc i
          if i >= args.len or args[i].startsWith("--"): invalid("arguments.missing_value")
          result.values[key] = args[i]
    else:
      result.positional.add(arg)
    inc i

proc has(o: Options, key: string): bool = o.values.hasKey(key)
proc value(o: Options, key: string, fallback = ""): string = o.values.getOrDefault(key, fallback)
proc allow(o: Options, keys: openArray[string]) =
  for key in o.values.keys:
    if key != "json" and key notin keys: invalid("arguments.unknown_option")
proc count(o: Options, low, high: int) =
  if o.positional.len < low or o.positional.len > high: invalid("arguments.invalid_count")
proc nameArg(o: Options): string =
  if o.has("name"):
    if o.positional.len > 0: invalid("arguments.duplicate_name")
    result = o.value("name")
  else:
    o.count(1, 1)
    result = o.positional[0]
  requireName(result)

proc requireSuccess(code: int) =
  if code != 0:
    var e = newException(EngineError, "operation.failed")
    e.code = "operation.failed"
    e.exitCode = code
    raise e

proc legacyCreate(name, snapshot: string): int =
  captureLegacy(proc(): int = cmdCreate(name, `from` = snapshot))
proc legacyDelete(name: string): int =
  captureLegacy(proc(): int = cmdDelete(name))

proc legacyAction(command: string, o: Options): JsonNode =
  case command
  of "ports":
    o.allow([]); o.count(0, 0)
    return portRows()
  of "bindings":
    o.allow([]); o.count(0, 0)
    return bindingRows()
  of "start", "stop", "ssh", "delete":
    o.allow(["name", "dry-run"])
    let name = o.nameArg()
    if o.has("dry-run") and command != "delete": invalid("arguments.unsupported_dry_run")
    if command == "ssh":
      let item = plainInspect(name)
      return %*{"name": name, "host": "localhost", "user": "dev", "ssh_port": item["ssh_port"]}
    if command == "delete" and o.has("dry-run"):
      return %*{"name": name, "action": "delete", "dry_run": true, "environment": plainInspect(name)}
    let code = captureLegacy(proc(): int =
      case command
      of "start": cmdStart(name)
      of "stop": cmdStop(name)
      else: cmdDelete(name))
    requireSuccess(code)
    return %*{"name": name, "action": command, "status": "completed"}
  of "create":
    o.allow(["name", "post-create", "from", "from-snapshot", "fresh"])
    let name = o.nameArg()
    if hasRecipeEnvironment(name): invalid("environment.recipe_state_exists")
    let code = captureLegacy(proc(): int = cmdCreate(name,
      postCreate = o.value("post-create"), fromSnapshot = o.value("from-snapshot"),
      `from` = o.value("from"), fresh = o.value("fresh", "false") == "true"))
    requireSuccess(code)
    return %*{"name": name, "instance": ContainerPrefix & name, "action": command,
      "status": "completed", "ssh_port": getPort(name)}
  of "import", "export":
    o.allow(["name", "file", "output"])
    if command == "import" and (not o.has("file") or o.has("output")): invalid()
    if command == "export" and o.has("file"): invalid()
    let name = o.nameArg()
    let code = captureLegacy(proc(): int =
      if command == "import": cmdImport(name, o.value("file"))
      else: cmdExport(name, o.value("output")))
    requireSuccess(code)
    result = %*{"name": name, "action": command, "status": "completed"}
    if command == "export":
      result["output_path"] = %o.value("output", getCurrentDir() / (name & ".tar.gz"))
    else: result["ssh_port"] = %getPort(name)
  of "bind", "unbind":
    o.allow(["name", "port", "list"])
    var position = o.positional
    let name = if o.has("name"): o.value("name")
               elif position.len > 0: position[0] else: ""
    requireName(name)
    if not o.has("name"): position.delete(0)
    if o.has("list"):
      if command != "bind" or position.len > 0 or o.has("port"): invalid()
      return bindingRows(name)
    if (o.has("port") and position.len != 0) or (not o.has("port") and position.len != 1): invalid()
    let port = if o.has("port"): o.value("port") else: position[0]
    let parsed = parsePortArg(port)
    if not parsed.valid or (command == "unbind" and ':' in port): invalid("port.invalid")
    let code = captureLegacy(proc(): int =
      if command == "bind": cmdBind(name, port)
      else: cmdUnbind(name, parsed.hostPort))
    requireSuccess(code)
    return %*{"name": name, "action": command, "status": "completed",
      "host_port": parsed.hostPort, "container_port": parsed.containerPort}
  of "shell": invalid("shell.interactive_only")
  else: invalid("command.unknown")

proc rebindResult(o: Options): JsonNode =
  o.allow(["name", "port"])
  var position = o.positional
  let name = if o.has("name"): o.value("name")
             elif position.len > 0: position[0] else: ""
  requireName(name)
  if not o.has("name"): position.delete(0)
  if (o.has("port") and position.len != 0) or (not o.has("port") and position.len != 1): invalid()
  let port = if o.has("port"): o.value("port") else: position[0]
  let parsed = parsePortArg(port)
  if not parsed.valid: invalid("port.invalid")
  proc owner(): string =
    for row in bindingRows():
      if row["host_port"].getInt == parsed.hostPort:
        if result.len > 0: invalid("ports.ambiguous_owner")
        result = row["name"].getStr
  let before = owner()
  let related = if before.len == 0: @[] else: @[before]
  trackOperation(name, "rebind", proc(): JsonNode =
    # Fail rather than switching to a newly discovered, unlocked owner.
    if owner() != before: invalid("ports.owner_changed")
    let fullOwner = if before.len == 0: "" else: ContainerPrefix & before
    let code = if o.has("json"):
                 captureLegacy(proc(): int = cmdRebindFrom(name, port, fullOwner))
               else: cmdRebindFrom(name, port, fullOwner)
    requireSuccess(code)
    %*{"name": name, "action": "rebind", "status": "completed",
       "host_port": parsed.hostPort, "container_port": parsed.containerPort}, related)

proc legacyResult(command: string, o: Options): JsonNode =
  if command == "rebind": return rebindResult(o)
  if command in ["create", "start", "stop", "delete", "bind", "unbind", "rebind", "import", "export"] and
      not o.has("dry-run") and not o.has("list"):
    let name = if o.has("name"): o.value("name")
               elif o.positional.len > 0: o.positional[0] else: ""
    requireName(name)
    return trackOperation(name, command, proc(): JsonNode = legacyAction(command, o))
  legacyAction(command, o)

proc perform(command: string, o: Options): JsonNode =
  case command
  of "recipe":
    o.allow([]); o.count(1, 2)
    case o.positional[0]
    of "list":
      o.count(1, 1); return listRecipes()
    of "validate":
      o.count(2, 2)
      let recipe = loadRecipe(o.positional[1])
      return %*{"valid": true, "id": recipe["id"], "digest": recipeDigest(recipe)}
    of "add":
      o.count(2, 2); return registerRecipe(o.positional[1])
    of "show":
      o.count(2, 2); return showRecipe(o.positional[1])
    else: invalid("recipe.unknown_action")
  of "project":
    o.allow([]); o.count(2, 2)
    if o.positional[0] != "validate": invalid("project.unknown_action")
    let project = loadProject(o.positional[1])
    let recipe = if project.hasKey("recipePath"): loadRecipe(project["recipePath"].getStr())
                 else: resolveRecipe(project["recipeId"].getStr())
    return %*{"valid": true, "id": project["id"], "recipe_id": recipe["id"],
      "seed_file_count": project["seedFiles"].len}
  of "create":
    if not o.has("recipe") and not o.has("project"): return legacyResult(command, o)
    o.allow(["name", "recipe", "project", "dry-run"])
    if o.has("recipe") and o.has("project"): invalid("create.conflicting_sources")
    return createEnvironment(o.nameArg(), o.value("recipe"), o.value("project"), o.has("dry-run"), legacyCreate)
  of "inspect":
    o.allow(["name"])
    let name = o.nameArg()
    if hasRecipeEnvironment(name): return inspectEnvironment(name)
    return plainInspect(name)
  of "setup":
    o.allow(["name", "dry-run", "rerun"])
    return setupEnvironment(o.nameArg(), o.has("dry-run"), o.has("rerun"))
  of "task":
    o.allow(["input-file"]); o.count(2, 3)
    let name = o.positional[1]
    requireName(name)
    case o.positional[0]
    of "list":
      o.count(2, 2)
      if o.has("input-file"): invalid()
      return taskList(name)
    of "run":
      o.count(3, 3)
      var inputs = newJObject()
      if o.has("input-file"):
        let path = o.value("input-file")
        if getFileSize(path) > 1024 * 1024: invalid("task.inputs_too_large")
        try: inputs = parseJson(readBoundedRegularFile(path, 1024 * 1024))
        except CatchableError: invalid("task.invalid_inputs")
        if inputs.kind != JObject: invalid("task.invalid_inputs")
      return taskRun(name, o.positional[2], inputs)
    else: invalid("task.unknown_action")
  of "runs":
    o.allow(["tail"]); o.count(2, 2)
    if o.has("tail") and o.positional[0] != "logs": invalid()
    case o.positional[0]
    of "list":
      requireName(o.positional[1]); return runsList(o.positional[1])
    of "show": return runShow(o.positional[1])
    of "logs":
      var tail = 100
      try: tail = parseInt(o.value("tail", "100"))
      except ValueError: invalid("logs.invalid_tail")
      return runLogs(o.positional[1], tail)
    else: invalid("runs.unknown_action")
  of "services":
    o.allow(["tail"]); o.count(2, 3)
    let action = o.positional[0]
    if action notin ["list", "start", "stop", "restart", "logs"]: invalid("services.unknown_action")
    if o.has("tail") and action != "logs": invalid()
    var tail = 100
    try: tail = parseInt(o.value("tail", "100"))
    except ValueError: invalid("services.invalid_tail")
    if tail < 1 or tail > 1000: invalid("services.invalid_tail")
    let name = o.positional[1]
    requireName(name)
    return services(name, action, (if o.positional.len == 3: o.positional[2] else: ""), tail)
  of "doctor":
    o.allow([]); o.count(0, 0); return doctorResult()
  of "delete":
    o.allow(["name", "dry-run"])
    let name = o.nameArg()
    if hasRecipeEnvironment(name): return deleteEnvironment(name, o.has("dry-run"), legacyDelete)
    return legacyResult(command, o)
  else: return legacyResult(command, o)

proc renderHuman(data: JsonNode) =
  ## Readable structured output without inventing a second semantic contract.
  if data.kind == JArray and data.len == 0: echo "No results."
  else: echo pretty(data)

const ExtendedHelp = """Recipe and automation commands:
  ocdev recipe validate|add|show <file-or-id> [--json]
  ocdev recipe list [--json]
  ocdev project validate <file> [--json]
  ocdev create <name> --recipe <file-or-id> | --project <file> [--dry-run] [--json]
  ocdev inspect <name> [--json]
  ocdev setup <name> --rerun [--dry-run] [--json]
  ocdev task list <name> [--json]
  ocdev task run <name> <task> [--input-file <json-file>] [--json]
  ocdev runs list <name> | show <run-id> [--json]
  ocdev runs logs <run-id> [--tail N] [--json]
  ocdev services list|start|stop|restart|logs <name> [service] [--tail N] [--json]
  ocdev doctor [--json]
  ocdev delete <name> [--dry-run] [--json]
Noninteractive legacy commands also accept --json, except exec (raw command I/O).
  ocdev exec <name> [--cwd <absolute-path>] -- <command> [args...]
shell is interactive only.
Recipes are trusted code and clone an existing container/snapshot.
"""

proc dispatchExtended*(args: seq[string]): tuple[handled: bool, code: int] =
  if args.len == 0: return (false, 0)
  if args[0] == "--":
    return dispatchExtended(args[1 .. ^1])
  if args[0].startsWith('-'):
    if args.len == 1 and args[0] in ["--help", "-h", "--version"]: return (false, 0)
    # Do not let legacy global-option parsing conceal a mutating subcommand.
    if "--json" in args:
      stderr.writeLine($( %*{"error": {"code": "arguments.command_required",
        "message": "Place the command before its options."}}))
    else: stderr.writeLine("Error: place the command before its options")
    return (true, 1)
  let groups = ["recipe", "project", "inspect", "setup", "task", "runs", "services", "doctor"]
  let legacy = ["create", "list", "start", "stop", "shell", "ssh", "delete", "ports",
    "bind", "unbind", "rebind", "bindings", "exec", "export", "import"]
  let normalized = optionNormalize(args[0])
  let matches = legacy.filterIt(it.startsWith(normalized))
  if matches.len > 1 and "exec" in matches:
    stderr.writeLine("Error: ambiguous command; use exec or export")
    return (true, 1)
  let command = if normalized in legacy or normalized in groups: normalized
                elif matches.len == 1: matches[0] else: args[0]
  # Canonicalize every spelling accepted by the legacy dispatch before routing;
  # otherwise abbreviations (sto/del) could bypass recipe hooks and locks.
  if command != args[0]:
    return dispatchExtended(@[command] & args[1 .. ^1])
  # Exec owns its delimiter and raw I/O contract. In particular, guest --help
  # and --json must not enter the ordinary CLI option scanning below.
  if command == "exec": return dispatchExec(args[1 .. ^1])
  if command == "list": return (false, 0) # Preserve the exact original contract.
  if "--help" in args and command notin groups: return (false, 0)
  let jsonMode = "--json" in args
  let mutations = ["start", "stop", "bind", "unbind", "rebind", "import", "export"]
  var relevant = command in groups or jsonMode or command in ["delete", "create"] or command in mutations
  if command in ["create", "delete"]:
    relevant = relevant or args.anyIt(it == "--dry-run" or it == "--recipe" or it == "--project" or
      it.startsWith("--recipe=") or it.startsWith("--project="))

  if not relevant: return (false, 0)
  if "--help" in args and command in groups:
    echo ExtendedHelp
    return (true, 0)
  try:
    let options = parseOptions(args[1 .. ^1])
    if command in mutations and command != "rebind" and not jsonMode:
      let name = if options.has("name"): options.value("name")
                 elif options.positional.len > 0: options.positional[0] else: ""
      requireName(name)
      if not hasRecipeEnvironment(name): return (false, 0)
    if command == "delete" and not jsonMode and not options.has("dry-run"):
      options.allow(["name"])
      if not hasRecipeEnvironment(options.nameArg()): return (false, 0)
    if command == "create" and not jsonMode and not options.has("recipe") and not options.has("project"):
      if hasRecipeEnvironment(options.nameArg()): invalid("environment.recipe_state_exists")
      if not options.has("dry-run"): return (false, 0)
    let data = perform(command, options)
    if jsonMode: echo $data
    elif command != "rebind": renderHuman(data) # Rebind preserves legacy human output.
    return (true, 0)
  except CatchableError as e:
    var code = "operation.failed"
    let candidate = e.msg.split(':')[0]
    if candidate.len > 0 and candidate.len < 100 and candidate.allIt(it.isAlphaNumeric or it in {'.', '_', '-'}):
      code = candidate
    let error = %*{"error": {"code": code,
      "message": "Command failed. Validate inputs and inspect operation history for recorded failures."}}
    if e of EngineError:
      let engineError = cast[ref EngineError](e)
      error["error"]["code"] = %engineError.code
      error["error"]["operationId"] = %engineError.operationId
    if jsonMode: stderr.writeLine($error)
    else: stderr.writeLine("Error: " & e.msg)
    let exitCode = if e of EngineError: max(1, cast[ref EngineError](e).exitCode) else: 1
    return (true, exitCode)
