## Local recipe lifecycle. Recipes are trusted executable configuration, not a sandbox.
import std/[json, os, strutils, posix, times, sysrand, algorithm, sequtils, math]
import std/unicode except strip, toLower, toUpper
import config, recipes, recipe_exec, container, ports, safe_input

type EngineError* = object of CatchableError
  code*: string
  operationId*: string
  exitCode*: int

proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}

proc token(): string =
  for b in urandom(16): result.add(toHex(b, 2).toLowerAscii)
proc root(): string = getOcdevDir()
proc validName(name: string) =
  if not validateName(name).valid:
    raise newException(ValueError, "Invalid environment name")
proc statePath(name: string): string =
  validName(name)
  root() / "environments" / (name & ".json")
proc privateDir(path: string) =
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
proc atomic(path: string; data: JsonNode) =
  privateDir(root())
  privateDir(parentDir(path))
  let temp = path & "." & token()
  let fd = posix.open(temp.cstring, O_CREAT or O_EXCL or O_WRONLY, Mode(0o600))
  if fd < 0: raise newException(IOError, "Cannot persist operation state")
  var f: File
  if not open(f, FileHandle(fd), fmWrite):
    discard posix.close(fd)
    raise newException(IOError, "Cannot persist operation state")
  try:
    f.write($data)
    f.flushFile()
    discard fsync(fd)
  finally: f.close()
  try: moveFile(temp, path)
  finally:
    if fileExists(temp): removeFile(temp)
proc readState(name: string): JsonNode =
  let path = statePath(name)
  if not fileExists(path): raise newException(ValueError, "Recipe environment not found")
  try:
    if getFileSize(path) > 4 * 1024 * 1024: raise newException(ValueError, "Invalid state")
    result = parseJson(readFile(path))
    if result.kind != JObject or result{"name"}.getStr != name or
        result{"digest"}.getStr != recipeDigest(result["recipe"]) or
        result{"uuid"}.isNil or result["uuid"].kind != JString:
      raise newException(ValueError, "Invalid state")
  except CatchableError: raise newException(IOError, "Invalid environment state")
proc hasRecipeEnvironment*(name: string): bool = fileExists(statePath(name))
proc locked[T](name: string; body: proc(): T {.closure.}): T =
  validName(name)
  privateDir(root())
  privateDir(root() / "environments")
  let path = root() / "environments" / (name & ".lock")
  let fd = posix.open(path.cstring, O_CREAT or O_RDWR or O_CLOEXEC, Mode(0o600))
  if fd < 0: raise newException(IOError, "Cannot open environment lock")
  defer: discard posix.close(fd)
  if flock(fd, 2 or 4) != 0: raise newException(IOError, "Environment operation already running")
  defer: discard flock(fd, 8)
  body()
proc backend(name: string; cancelled: CancellationCheck = nil): JsonNode =
  # Filter before serializing: unrelated fleet metadata must not exhaust our cap.
  let r = execute(@["incus", "list", "--format=json", "^" & ContainerPrefix & name & "$"],
    limit = 2 * 1024 * 1024, cancelled = cancelled)
  if r.code != 0 or r.truncated: raise newException(IOError, "Incus instance query failed")
  try: result = parseJson(r.output)
  except CatchableError: raise newException(IOError, "Malformed Incus instance response")
  if result.kind != JArray: raise newException(IOError, "Malformed Incus instance response")
  for item in result:
    if item.kind != JObject or not item.hasKey("name") or item["name"].kind != JString or
        not item.hasKey("status") or item["status"].kind != JString or
        not item.hasKey("config") or item["config"].kind != JObject:
      raise newException(IOError, "Malformed Incus instance response")
proc query(path: string): JsonNode =
  let r = execute(@["incus", "query", path])
  if r.code != 0 or r.truncated: raise newException(IOError, "Incus preflight query failed")
  try: result = parseJson(r.output)
  except CatchableError: raise newException(IOError, "Malformed Incus preflight response")
  if result.kind != JObject: raise newException(IOError, "Malformed Incus preflight response")
proc observe(name: string; cancelled: CancellationCheck = nil): JsonNode =
  for item in backend(name, cancelled):
    if item["name"].getStr == ContainerPrefix & name: return item
  newJNull()
proc guard(state: JsonNode; running = true; cancelled: CancellationCheck = nil): JsonNode =
  result = observe(state["name"].getStr, cancelled)
  if result.kind == JNull: raise newException(IOError, "Managed instance is missing")
  if state{"uuid"}.getStr == "" or result{"config", "volatile.uuid"}.getStr != state["uuid"].getStr:
    raise newException(IOError, "Instance identity does not match pinned environment")
  if running and result["status"].getStr.toLowerAscii != "running":
    raise newException(IOError, "Managed instance is not running")
proc withRunningEnvironment*(name: string; body: proc(): int {.closure.};
    cancelled: CancellationCheck = nil): int =
  ## Ad-hoc execution shares lifecycle guards, but creates no task/run history.
  locked(name, proc(): int =
    if hasRecipeEnvironment(name):
      discard guard(readState(name), cancelled = cancelled)
    else:
      let instance = observe(name, cancelled)
      if instance.kind == JNull: raise newException(IOError, "Container not found")
      if instance["status"].getStr.toLowerAscii != "running":
        raise newException(IOError, "Container is not running; start it first")
    body())

proc hooks(state: JsonNode; hook: string): JsonNode =
  result = state{"recipe", "hooks", hook}
  if result.isNil: result = newJArray()
proc summary(state: JsonNode): JsonNode =
  %*{"name": state["name"], "recipeId": state["recipe"]["id"],
     "recipeDigest": state["digest"], "uuid": state{"uuid"}.getStr,
     "setupStatus": state{"setupStatus"}.getStr, "servicesReady": "unknown"}
proc save(state: JsonNode) = atomic(statePath(state["name"].getStr), state)
proc record(op: JsonNode) = atomic(root() / "runs" / (op["id"].getStr & ".json"), op)
proc operation(name, kind: string; body: proc(op: JsonNode): JsonNode {.closure.}): JsonNode =
  let op = %*{"id": token(), "name": name, "kind": kind, "status": "running",
              "startedAt": $now().utc, "steps": []}
  record(op)
  try:
    result = body(op)
    op["status"] = %"complete"
    op["finishedAt"] = %($now().utc)
    record(op)
    if result.kind == JObject: result["operationId"] = op["id"]
  except CatchableError as cause:
    op["errorCode"] = %("recipe." & kind & ".failed")
    op["status"] = %"failed"
    op["finishedAt"] = %($now().utc)
    for step in op["steps"]:
      if step["status"].getStr == "running": step["status"] = %"failed"
    record(op)
    let error = newException(EngineError, "Recipe " & kind & " failed; operation ID: " & op["id"].getStr)
    error.code = "recipe." & kind & ".failed"
    error.operationId = op["id"].getStr
    error.exitCode = if cause of EngineError: max(1, cast[ref EngineError](cause).exitCode) else: 1
    raise error

proc trackOperation*(name, kind: string; body: proc(): JsonNode {.closure.};
    relatedNames: seq[string] = @[]): JsonNode =
  # Rebind mutates both endpoints. Acquire every lock in a stable order, then
  # validate pinned identities while those locks are held, including stopped
  # containers (start/stop and proxy-device changes do not require a running guest).
  let names = (@[name] & relatedNames).deduplicate().sorted()
  proc acquire(index: int): JsonNode =
    if index < names.len:
      return locked(names[index], proc(): JsonNode = acquire(index + 1))
    operation(name, kind, proc(op: JsonNode): JsonNode =
      for target in names:
        if hasRecipeEnvironment(target): discard guard(readState(target), running = false)
      body())
  acquire(0)

proc step(op: JsonNode; kind, name: string; body: proc() {.closure.}) =
  let s = %*{"kind": kind, "name": name, "status": "running"}
  op["steps"].add(s)
  record(op)
  body()
  s["status"] = %"complete"
  record(op)
proc seedsPreflight(project: JsonNode) =
  if project.isNil or not project.hasKey("seedFiles"): return
  for seed in project["seedFiles"]:
    let source = seed["source"].getStr
    if not fileExists(source):
      if seed{"required"}.getBool: raise newException(IOError, "Required project file unavailable")
      continue
    if getFileSize(source) > 16 * 1024 * 1024: raise newException(IOError, "Project file exceeds size limit")
    discard readBoundedRegularFile(source, 16 * 1024 * 1024)
    let dest = seed["destination"].getStr
    let mode = seed["mode"].getStr
    if not dest.isAbsolute or dest == "/" or dest.contains('\x00') or mode.len notin 3..4:
      raise newException(ValueError, "Invalid project file destination or mode")
    for c in mode:
      if c notin {'0'..'7'}: raise newException(ValueError, "Invalid project file mode")
proc remote(state: JsonNode; cwd: string; args: seq[string]; input = ""; timeoutMs = 300000): ExecResult =
  discard guard(state)
  execute(@["incus", "exec", ContainerPrefix & state["name"].getStr,
    "--cwd", cwd, "--", "runuser", "-u", "dev", "--", "timeout", "--signal=TERM",
    "--kill-after=5s", $(max(1, (timeoutMs + 999) div 1000)) & "s"] & args,
    input, timeoutMs + 10000)
proc checked(r: ExecResult) =
  if r.code != 0: raise newException(IOError, "Environment command failed")
proc inputValues(state: JsonNode; taskName: string; provided: JsonNode): JsonNode =
  if provided.kind != JObject: raise newException(ValueError, "Task inputs must be an object")
  let task = state["recipe"]["tasks"][taskName]
  let defs = task{"inputs"}
  result = newJObject()
  let defaults = state{"project", "inputDefaults", taskName}
  if not defaults.isNil:
    for key, value in defaults: result[key] = value
  for key, value in provided: result[key] = value
  for key, value in result:
    if defs.isNil or not defs.hasKey(key): raise newException(ValueError, "Unknown task input")
  if defs.isNil: return
  for key, spec in defs:
    if not result.hasKey(key) and spec.hasKey("default"): result[key] = spec["default"]
    if not result.hasKey(key):
      if spec{"required"}.getBool: raise newException(ValueError, "Required task input missing")
      continue
    let value = result[key]
    let good = case spec["type"].getStr
      of "string": value.kind == JString
      of "stringList": value.kind == JArray
      of "number": value.kind in {JInt, JFloat}
      of "boolean": value.kind == JBool
      else: false
    if not good: raise newException(ValueError, "Invalid task input type")
    if value.kind == JFloat and classify(value.getFloat) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "Task input must be finite")
    if spec{"required"}.getBool and ((value.kind == JString and value.getStr.strip.len == 0) or
        (value.kind == JArray and value.len == 0)):
      raise newException(ValueError, "Required task input is empty")
    if spec["type"].getStr == "stringList":
      for item in value:
        if item.kind != JString: raise newException(ValueError, "Invalid task input type")
    if spec.hasKey("choices"):
      if value.kind == JArray:
        for item in value:
          if item notin spec["choices"].elems: raise newException(ValueError, "Invalid task input choice")
      elif value notin spec["choices"].elems: raise newException(ValueError, "Invalid task input choice")
proc redactLog(output: string; secrets: seq[string]): string =
  var text = output
  if validateUtf8(text) >= 0:
    for i in 0 ..< text.len:
      if ord(text[i]) >= 128: text[i] = '?'
  for secret in secrets:
    if secret.len > 0: text = text.replace(secret, "[redacted]")
  var lines: seq[string]
  for line in text.splitLines():
    let lower = line.toLowerAscii
    if ["secret", "token", "password", "credential", "authorization", "private key"].anyIt(lower.contains(it)):
      lines.add("[redacted]")
    else: lines.add(line)
  lines.join("\n")

proc appendTaskLog(op: JsonNode; name: string; r: ExecResult; secrets: seq[string]) =
  let path = root() / "runs" / "logs" / (op["id"].getStr & ".json")
  var data = if fileExists(path): parseJson(readFile(path)) else: %*{"entries": [], "truncated": false}
  var text = redactLog(r.output, secrets)
  let truncated = r.truncated or text.len > 16384
  if text.len > 16384:
    text.setLen(16384)
    while validateUtf8(text) >= 0: text.setLen(text.len - 1)
  data["entries"].add(%*{"task": name, "output": text, "truncated": truncated})
  if truncated: data["truncated"] = %true
  while ($data).len > 262144 and data["entries"].len > 1:
    data["entries"].elems.delete(0)
    data["truncated"] = %true
  atomic(path, data)

proc hooksPreflight(state: JsonNode) =
  # Hooks cannot prompt for inputs: both setup and cleanup must be satisfiable.
  for kind in ["afterCreate", "beforeDelete"]:
    for name in hooks(state, kind):
      discard inputValues(state, name.getStr, newJObject())

proc runTask(state, op: JsonNode; name: string; inputs: JsonNode) =
  if not state["recipe"]["tasks"].hasKey(name): raise newException(ValueError, "Task not found")
  let task = state["recipe"]["tasks"][name]
  let values = inputValues(state, name, inputs)
  var args: seq[string]
  if task["kind"].getStr == "command": args = @[task["command"].getStr]
  else: args = @["task", "--taskfile", task["taskfile"].getStr, task["task"].getStr]
  if task.hasKey("args"):
    for arg in task["args"]: args.add(arg.getStr)
  step(op, "task", name, proc() =
    let r = remote(state, task["cwd"].getStr, args,
      (if values.len > 0: $values & "\n" else: ""), task{"timeoutMs"}.getInt(300000))
    op["steps"][^1]["exitCode"] = %r.code
    var secrets: seq[string]
    if task.hasKey("inputs"):
      for key, spec in task["inputs"]:
        if spec{"secret"}.getBool and values.hasKey(key):
          if values[key].kind == JString: secrets.add(values[key].getStr)
          elif values[key].kind == JArray:
            for value in values[key]: secrets.add(value.getStr)
          else: secrets.add($values[key])
    appendTaskLog(op, name, r, secrets)
    op["steps"][^1]["logAvailable"] = %true
    checked(r))
proc serviceExec(state: JsonNode; action, service: string; tail: int): ExecResult =
  let pc = state["recipe"]{"processCompose"}
  if pc.isNil: raise newException(ValueError, "Recipe has no process-compose configuration")
  # A dedicated Unix socket avoids the supervisor's shared default TCP port.
  # projectName is a local adapter label, not process-compose's numeric -p flag.
  let label = pc{"projectName"}.getStr(state["name"].getStr)
  let socket = "/tmp/ocdev-pc-" & label[0..<min(label.len, 24)] & "-" &
    state["name"].getStr & "-" & state["digest"].getStr[0..<8] & ".sock"
  var args = @[pc{"binary"}.getStr("process-compose"), "--unix-socket", socket]
  if service.len == 0 and action in ["stop", "restart"]:
    let listing = serviceExec(state, "list", "", tail)
    checked(listing)
    var items: JsonNode
    try: items = parseJson(listing.output)
    except CatchableError: raise newException(IOError, "Malformed process-compose response")
    if listing.truncated or items.kind != JArray: raise newException(IOError, "Malformed process-compose response")
    for item in items:
      let target = item{"name"}.getStr
      if target.len == 0 or target[0] == '-': raise newException(IOError, "Malformed process-compose response")
      if pc.hasKey("services") and %target notin pc["services"]: continue
      result = serviceExec(state, action, target, tail)
      if result.code != 0: return
    return
  case action
  of "up": args.add(@["up", "-f", pc["file"].getStr, "--detached"])
  of "list": args.add(@["process", "list", "--output", "json"])
  of "logs": args.add(@["process", "logs", service, "--tail", $tail])
  of "start", "stop", "restart":
    if action == "start" and service.len == 0:
      args.add(@["up", "-f", pc["file"].getStr, "--detached"])
    else:
      args.add(@["process", action, service])
  else: raise newException(ValueError, "Unsupported service action")
  remote(state, pc["cwd"].getStr, args)
proc setup(state, op: JsonNode) =
  state["setupStatus"] = %"running"
  save(state)
  try:
    let project = state{"project"}
    seedsPreflight(project)
    hooksPreflight(state)
    if not project.isNil and project.hasKey("seedFiles"):
      for seed in project["seedFiles"]:
        if not fileExists(seed["source"].getStr): continue
        step(op, "seed", seed["id"].getStr, proc() =
          let destination = seed["destination"].getStr
          let content = readBoundedRegularFile(seed["source"].getStr, 16 * 1024 * 1024)
          checked(remote(state, "/", @["mkdir", "-p", "--", parentDir(destination)]))
          # Private same-directory staging prevents partial files and symlink following.
          # The script is fixed; destinations/mode are argv and content only stdin.
          checked(remote(state, "/", @["sh", "-c",
            "set -eu; temp=$(mktemp -- \"$1/.ocdev-seed-XXXXXXXX\"); " &
            "trap 'rm -f -- \"$temp\"' EXIT; cat > \"$temp\"; " &
            "chmod -- \"$2\" \"$temp\"; mv -fT -- \"$temp\" \"$3\"",
            "ocdev-seed", parentDir(destination), seed["mode"].getStr, destination], content)))
    for hook in hooks(state, "afterCreate"): runTask(state, op, hook.getStr, newJObject())
    if state["recipe"].hasKey("processCompose") and state["recipe"]["processCompose"]{"autostart"}.getBool:
      step(op, "services", "start", proc() = checked(serviceExec(state, "up", "", 0)))
    state["setupStatus"] = %"complete"
    save(state)
  except CatchableError:
    state["setupStatus"] = %"failed"
    save(state)
    raise
proc preview(state: JsonNode; action: string): JsonNode =
  result = summary(state)
  result["dryRun"] = %true
  result["action"] = %action
  result["hooks"] = hooks(state, if action == "delete": "beforeDelete" else: "afterCreate")
  result["sourceSnapshot"] = state["recipe"]["source"]["snapshot"]
  result["allocations"] = %"provisional"
  if action == "delete": result["ownedResources"] = %*[ContainerPrefix & state["name"].getStr]
proc createEnvironment*(name, recipeRef, projectPath: string; dryRun: bool;
    clone: proc(name, snapshot: string): int {.closure.}): JsonNode =
  validName(name)
  if recipeRef.len > 0 and projectPath.len > 0: raise newException(ValueError, "Select recipe or project, not both")
  var project = newJObject()
  var reference = recipeRef
  if projectPath.len > 0:
    project = loadProject(projectPath)
    reference = project{"recipePath"}.getStr(project{"recipeId"}.getStr)
  let recipe = resolveRecipe(reference)
  let state = %*{"name": name, "recipe": recipe, "digest": recipeDigest(recipe),
    "project": project, "uuid": "", "setupStatus": "pending"}
  # Never persist secret defaults, even if a future schema permits them.
  for taskName, task in recipe["tasks"]:
    if task.hasKey("inputs"):
      for key, spec in task["inputs"]:
        if spec{"secret"}.getBool:
          if spec.hasKey("default") or not project{"inputDefaults", taskName, key}.isNil:
            raise newException(ValueError, "Secret defaults are not supported")
  proc preflight() =
    hooksPreflight(state)
    if hasRecipeEnvironment(name): raise newException(ValueError, "Recipe environment already recorded")
    if observe(name).kind != JNull: raise newException(ValueError, "Instance already exists")
    seedsPreflight(project)
    let snapshot = recipe["source"]["snapshot"].getStr
    let base = "/1.0/instances/" & ContainerPrefix & snapshot.split('/')[0]
    let source = query(base & "/snapshots/" & snapshot.split('/')[1])
    if source{"name"}.getStr == "": raise newException(IOError, "Malformed snapshot response")
    let instance = query(base & "?recursion=1")
    let pool = instance{"expanded_devices", "root", "pool"}.getStr
    if pool.len == 0 or pool.contains('/') or pool.contains('?'): raise newException(IOError, "Invalid source storage metadata")
    let storage = query("/1.0/storage-pools/" & pool)
    let driver = storage{"driver"}.getStr
    if driver.len == 0 or driver == "dir": raise newException(IOError, "Source requires a copy-on-write storage pool")
    state["sourceIdentity"] = %*{"snapshot": source["name"], "uuid": source{"config", "volatile.uuid"}.getStr}
  if dryRun:
    preflight()
    return preview(state, "create")
  locked(name, proc(): JsonNode =
    operation(name, "create", proc(op: JsonNode): JsonNode =
      step(op, "preflight", "source-and-project", proc() = preflight())
      save(state)
      step(op, "clone", name, proc() =
        try:
          if clone(name, recipe["source"]["snapshot"].getStr) != 0: raise newException(IOError, "Clone failed")
          let observed = observe(name)
          if observed.kind == JNull or observed{"config", "volatile.uuid"}.getStr == "": raise newException(IOError, "Clone identity unavailable")
          state["uuid"] = observed["config"]["volatile.uuid"]
          save(state)
        except CatchableError:
          # Release only local state after positively observing no instance.
          # An unknown/replaced instance must never be adopted just by name.
          try:
            if observe(name).kind == JNull:
              removeFile(statePath(name))
              # The clone callback owns its port reservation. We must not
              # release a reservation acquired by a competing plain creator.
          except CatchableError: discard
          raise)
      setup(state, op)
      summary(state)))
proc setupEnvironment*(name: string; dryRun, rerun: bool): JsonNode =
  if dryRun:
    let state = readState(name)
    discard guard(state)
    seedsPreflight(state{"project"})
    hooksPreflight(state)
    return preview(state, "setup")
  locked(name, proc(): JsonNode =
    operation(name, "setup", proc(op: JsonNode): JsonNode =
      let state = readState(name)
      discard guard(state)
      if not rerun: raise newException(ValueError, "Setup requires explicit rerun")
      setup(state, op)
      summary(state)))
proc inspectEnvironment*(name: string): JsonNode =
  let state = readState(name)
  let observed = observe(name)
  result = summary(state)
  result["exists"] = %(observed.kind != JNull)
  result["containerRunning"] = %(observed.kind != JNull and observed["status"].getStr.toLowerAscii == "running")
  result["identityMatches"] = %(observed.kind != JNull and state{"uuid"}.getStr != "" and observed{"config", "volatile.uuid"}.getStr == state["uuid"].getStr)
proc taskList*(name: string): JsonNode =
  let state = readState(name)
  result = newJArray()
  for key, task in state["recipe"]["tasks"]:
    var inputs = newJObject()
    if task.hasKey("inputs"):
      for field, spec in task["inputs"]:
        inputs[field] = %*{"type": spec["type"], "required": spec{"required"}.getBool, "secret": spec{"secret"}.getBool}
    result.add(%*{"name": key, "kind": task["kind"], "inputs": inputs})
proc taskRun*(name, taskName: string; inputs: JsonNode): JsonNode =
  locked(name, proc(): JsonNode =
    operation(name, "task", proc(op: JsonNode): JsonNode =
      let state = readState(name)
      runTask(state, op, taskName, inputs)
      %*{"name": name, "task": taskName, "status": "complete"}))
proc runShow*(id: string): JsonNode =
  if id.len != 32: raise newException(ValueError, "Invalid operation ID")
  for c in id:
    if c notin {'0'..'9', 'a'..'f'}: raise newException(ValueError, "Invalid operation ID")
  try:
    let path = root() / "runs" / (id & ".json")
    if getFileSize(path) > 4 * 1024 * 1024: raise newException(ValueError, "Invalid operation")
    let raw = parseJson(readFile(path))
    if raw.kind != JObject: raise newException(ValueError, "Invalid operation")
    result = newJObject()
    for key in ["id", "name", "kind", "status", "startedAt"]:
      if not raw.hasKey(key) or raw[key].kind != JString: raise newException(ValueError, "Invalid operation")
      result[key] = raw[key]
    if result["id"].getStr != id: raise newException(ValueError, "Invalid operation")
    validName(result["name"].getStr)
    for key in ["finishedAt", "errorCode"]:
      if raw.hasKey(key):
        if raw[key].kind != JString: raise newException(ValueError, "Invalid operation")
        result[key] = raw[key]
    if not raw.hasKey("steps") or raw["steps"].kind != JArray: raise newException(ValueError, "Invalid operation")
    result["steps"] = newJArray()
    for s in raw["steps"]:
      if s.kind != JObject: raise newException(ValueError, "Invalid step")
      let publicStep = newJObject()
      for key in ["kind", "name", "status"]:
        if not s.hasKey(key) or s[key].kind != JString: raise newException(ValueError, "Invalid step")
        publicStep[key] = s[key]
      for key in ["exitCode", "reason", "logAvailable"]:
        if s.hasKey(key):
          let expected = if key == "exitCode": JInt elif key == "logAvailable": JBool else: JString
          if s[key].kind != expected: raise newException(ValueError, "Invalid step")
          publicStep[key] = s[key]
      result["steps"].add(publicStep)
  except CatchableError: raise newException(IOError, "Operation record unavailable")
  if result{"status"}.getStr == "running":
    let path = root() / "environments" / (result["name"].getStr & ".lock")
    let fd = posix.open(path.cstring, O_RDONLY)
    if fd >= 0:
      if flock(fd, 2 or 4) == 0:
        result["status"] = %"interrupted"
        for s in result["steps"]:
          if s["status"].getStr == "running": s["status"] = %"interrupted"
        discard flock(fd, 8)
      discard posix.close(fd)
proc runLogs*(id: string; tail = 100): JsonNode =
  if tail < 1 or tail > 1000: raise newException(ValueError, "Log tail must be between 1 and 1000")
  discard runShow(id)
  let path = root() / "runs" / "logs" / (id & ".json")
  var data = if fileExists(path): parseJson(readFile(path)) else: %*{"entries": [], "truncated": false}
  var lines: seq[string]
  for entry in data["entries"]:
    lines.add("[" & entry["task"].getStr & "]")
    lines.add(entry["output"].getStr.splitLines())
  let start = max(0, lines.len - tail)
  let text = if lines.len > 0: lines[start .. ^1].join("\n") else: ""
  %*{"operationId": id, "logs": text, "truncated": data["truncated"].getBool or start > 0,
    "sensitive": true}

proc runsList*(name: string): JsonNode =
  validName(name)
  result = newJArray()
  let dir = root() / "runs"
  if not dirExists(dir): return
  var paths: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"): paths.add(path)
  paths.sort()
  for path in paths:
    let op = runShow(splitFile(path).name)
    if op["name"].getStr == name: result.add(op)
proc services*(name, action, service: string; tail: int): JsonNode =
  if tail < 1 or tail > 1000: raise newException(ValueError, "Log tail must be between 1 and 1000")
  locked(name, proc(): JsonNode =
    operation(name, "services", proc(op: JsonNode): JsonNode =
      let state = readState(name)
      let pc = state["recipe"]{"processCompose"}
      if pc.isNil: raise newException(ValueError, "Recipe has no process-compose configuration")
      if service.len > 0:
        if service[0] == '-' or service.contains('\x00'): raise newException(ValueError, "Invalid service name")
        if pc.hasKey("services") and %service notin pc["services"]: raise newException(ValueError, "Undeclared service")
      if action == "logs" and service.len == 0: raise newException(ValueError, "Select a service for logs")
      var r: ExecResult
      step(op, "services", action, proc() =
        r = serviceExec(state, action, service, tail)
        op["steps"][^1]["exitCode"] = %r.code
        checked(r))
      result = %*{"name": name, "action": action, "status": "complete", "servicesReady": "unknown"}
      if action == "list":
        var items: JsonNode
        try: items = parseJson(r.output)
        except CatchableError: raise newException(IOError, "Malformed process-compose response")
        if r.truncated or items.kind != JArray: raise newException(IOError, "Malformed process-compose response")
        result = newJArray()
        for item in items:
          if item.kind != JObject or item{"name"}.isNil or item["name"].kind != JString: raise newException(IOError, "Malformed service entry")
          result.add(%*{"name": item["name"], "status": item{"status"}.getStr("unknown"), "ready": "unknown"})
      elif action == "logs":
        # Omit credential-shaped lines; arbitrary program output remains sensitive.
        var lines: seq[string]
        for line in redactLog(r.output, @[]).splitLines:
          lines.add(line)
        let start = max(0, lines.len - tail)
        result["logs"] = %lines[start..^1].join("\n")
        result["truncated"] = %(r.truncated or start > 0)
        result["sensitive"] = %true))
proc deleteEnvironment*(name: string; dryRun: bool;
    remove: proc(name: string): int {.closure.}): JsonNode =
  if dryRun:
    let state = readState(name)
    let observed = observe(name)
    if observed.kind != JNull: discard guard(state, false)
    result = preview(state, "delete")
    result["metadataOnly"] = %(observed.kind == JNull)
    result["hooksSkipped"] = %(observed.kind == JNull)
    return
  locked(name, proc(): JsonNode =
    operation(name, "delete", proc(op: JsonNode): JsonNode =
      let state = readState(name)
      if observe(name).kind == JNull:
        # Authoritative absence permits local reconciliation, never a name-based
        # adoption/deletion of a replacement instance. Missing hooks cannot run.
        for hook in hooks(state, "beforeDelete"):
          op["steps"].add(%*{"kind": "task", "name": hook, "status": "skipped", "reason": "instance_missing"})
        step(op, "reconcile", name, proc() =
          removePort(name)
          removeFile(statePath(name)))
        return %*{"name": name, "status": "deleted", "metadataOnly": true}
      discard guard(state, false)
      for hook in hooks(state, "beforeDelete"): runTask(state, op, hook.getStr, newJObject())
      step(op, "delete", name, proc() =
        discard guard(state, false)
        if remove(name) != 0: raise newException(IOError, "Instance deletion failed")
        if observe(name).kind != JNull: raise newException(IOError, "Instance still exists")
        removeFile(statePath(name)))
      %*{"name": name, "status": "deleted"}))
