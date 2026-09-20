# Recipes and projects

Recipes describe trusted tasks in an environment cloned from an **existing ocdev snapshot**. Projects select a recipe and reference local files to deliver to that environment. The CLI stays Nim; tasks may use whatever tools their snapshot provides. There is no recipe build engine, remote registry, image builder, cloud database adapter, or agent manager.

## Implemented CLI

Run these from the repository root with `bin/ocdev`, or use an installed `ocdev`:

```sh
ocdev recipe validate examples/recipes/node-redis.yaml --json
ocdev project validate examples/projects/node-redis/project.yaml --json
ocdev recipe add examples/recipes/node-redis.yaml --json
ocdev recipe list --json
ocdev recipe show node-redis --json

# Requires a prepared snapshot and Incus, even for this preview.
ocdev create node-demo --project examples/projects/node-redis/project.yaml --dry-run --json
# This clones and executes afterCreate tasks; run only after reviewing the preview.
ocdev create node-demo --project examples/projects/node-redis/project.yaml --json
ocdev inspect node-demo --json
ocdev task list node-demo --json
ocdev task run node-demo test --json
ocdev setup node-demo --dry-run --json
ocdev setup node-demo --rerun --json
ocdev runs list node-demo --json
ocdev runs show <run-id> --json
ocdev runs logs <run-id> --tail 100 --json
ocdev services list node-demo --json
ocdev services restart node-demo web --json
ocdev services logs node-demo web --tail 100 --json
ocdev doctor --json
ocdev delete node-demo --dry-run --json
ocdev delete node-demo --json
```

`recipe validate` and `recipe add` take files; `recipe show` and `create --recipe` accept a local file or registered ID. Use `create --recipe` **or** `create --project`, never both. Recipe creation rejects legacy `--from`, `--from-snapshot`, and `--post-create` overrides. A project is explicitly selected; there is no automatic discovery or override-file merge.

`recipe validate` checks the definition without Incus. `project validate` also resolves and validates its selected recipe, but **does not check seed-file availability or snapshot existence**. Creation preflight checks seed readability/size and queries the snapshot and source storage. `--dry-run` does not clone, seed, run hooks, reserve ports, or write environment/operation state; allocations are labeled provisional. It is not an offline mode.

Noninteractive legacy operations also accept `--json`, including create/start/stop/delete, ports/bindings, bind/unbind/rebind, SSH connection information, and import/export. Plain `create --json` honors the user-wide `~/.ocdev/config.json` defaults and `--fresh`, just like ordinary creation. Recipes always use their declared snapshot source; `--fresh` cannot be combined with `--recipe` or `--project`. Interactive `shell --json` is rejected. Ad-hoc `exec` is also an exception: `ocdev exec <name> -- <command> [args...]` forwards raw stdin/stdout/stderr and the exit status, without an ocdev JSON envelope or task/run history. It still holds the environment lock and checks pinned identity. Command flags after `--`, including a program's own `--json`, are passed through. The existing `list --json` array contract is unchanged. Legacy command abbreviations/normalization are resolved before recipe routing so they cannot bypass hooks or locks. Place the command before its options; only standalone help/version options are supported before a command.

## Two example workflows

| Project | Snapshot prerequisites | Application contract |
| --- | --- | --- |
| `examples/projects/node-redis/project.yaml` | Existing `node-base/ready`; Node supporting `--env-file`, npm, Docker with Compose, process-compose | Checkout at `/home/dev/workspace/app`; `package.json`, lockfile, `server.js`, and `npm test`; server reads `PORT` and `REDIS_URL` |
| `examples/projects/python-postgres/project.yaml` | Existing `python-base/ready`; Python with venv/pip, Docker with Compose, process-compose | Checkout at `/home/dev/workspace/app`; `requirements.txt` providing uvicorn, pytest, and application dependencies; ASGI `app:app`; application reads `DATABASE_URL` |

These are **workflow templates**, not bundled application source or prebuilt snapshots. Prepare trusted snapshots with existing Incus/ocdev workflows, or change each recipe's source and paths in your own copy. The source uses the same logical `container/snapshot` naming convention as existing `ocdev create --from`; ocdev applies its container prefix internally. A copy-on-write source storage pool is required; `dir` storage is rejected by recipe preflight.

The environment must have user `dev`, `runuser`, GNU-compatible `timeout`, and writable application directories. Tasks run as `dev` via `incus exec`. Docker must already be running and usable by `dev`; permissions to a Docker socket confer substantial privilege. Examples do not install Docker or process-compose.

Each project delivers three files **before** hooks: dummy `.env.example` to application `.env` with mode `0600`, Docker Compose configuration, and process-compose configuration. Node setup runs `npm ci` and starts Redis; Python setup creates a venv, installs requirements, and starts PostgreSQL. Neither example runs application database migrations or seeds automatically. Both start the process-compose web process after successful hooks.

Redis/PostgreSQL bind only to loopback **inside the environment**. The PostgreSQL password is deliberately public dummy data for this disposable example; replace it in private configuration for any real use. Docker Compose uses the environment's Docker daemon, never a host socket mount. Do not run these examples against a snapshot that mounts a shared host Docker socket.

There is no database readiness wait in these templates. Applications must retry database connections; process-compose restart policies are not a readiness guarantee. Use `task run <name> test` explicitly after dependencies are ready. Web ports are 3000 and 8000 respectively; use ocdev's existing binding commands if host access is wanted. `services` manages the declared process-compose `web` process, **not** the Docker database service. The database is managed by the named recipe tasks.

The Python process-compose command sources `.env` as shell syntax. Treat that file as trusted code, not arbitrary untrusted dotenv text. Before-delete hooks run Docker Compose `down` without deleting named volumes; deleting the environment subsequently removes its local filesystem. Nothing here manages a shared external database.

These definitions have been schema-validated with the compiled CLI. No example snapshot has been cloned, no package installation or application task has run, and no live service compatibility is claimed.

## Definition schema

YAML (`.yaml`, `.yml`) and JSON (`.json`) use the same strict schema. Definitions are limited to 1 MiB and 32 nested collections. Duplicate mapping keys, YAML anchors/aliases, custom tags, multiple documents, unknown fields, and unsupported versions are rejected.

A recipe requires:

- `schemaVersion: 1`, a safe `id`, and a nonempty `name`.
- `source: {snapshot: "base/ready"}`; optional `provider` must be `ocdev`.
- `tasks`: an object keyed by safe task IDs; it may be empty.

Task fields:

- `kind: command`, `command`, optional string-array `args`; or `kind: taskfile`, `taskfile`, `task`. A Taskfile task requires the `task` executable in its snapshot.
- Absolute environment `cwd`; parent traversal is rejected. Optional `plane` can only be `env`.
- Optional `timeoutMs` from 1 to 86400000; execution defaults to 300000 ms.
- Optional `description`, and `inputs` keyed by letter-leading alphanumeric/underscore names.
- Inputs have `type: string|stringList|number|boolean`, optional `required`, `secret`, `default`, `description`, and string/stringList-only `choices`. Secret inputs cannot have defaults or choices.

`hooks` optionally contains ordered `afterCreate` and `beforeDelete` arrays referencing declared tasks. Creation preflight verifies that both hook lists can resolve required inputs from nonsecret recipe/project defaults; hooks cannot prompt or consume a task input file. Required-secret tasks remain available for explicit task runs but cannot be automatic hooks. No DAG, database-specific hooks, agent sessions, cloud-provider configuration, capabilities, actions, or output-report schemas are supported.

Optional `processCompose` contains absolute `cwd`, `file` (relative to that cwd or absolute), and optional `binary`, `projectName`, `autostart`, `services`. The adapter runs the configured binary in the environment; parsing does not verify its availability or validate the external process-compose file.

A project requires `schemaVersion: 1`, `id`, and exactly one of `recipePath` or `recipeId`; `name` is optional. `seedFiles` is an optional array of `{id, source, destination, mode, required}`. Destinations are safe absolute environment file paths. Use quoted four-digit octal modes, such as `"0600"`; duplicate IDs/destinations are rejected. Host `source` and `recipePath` resolve against the project file's directory, not the shell's cwd; `~/` expands locally. Seed files must resolve to regular files and are limited to 16 MiB at creation/setup preflight and delivery. No seed contents enter the project definition or registration record.

Optional project `inputDefaults` has shape `{taskName: {inputName: value}}`. Only declared, correctly typed, nonsecret inputs are allowed. Selecting a registered recipe with defaults requires that ID to be registered when validating the project.

## Inputs, pinning, and reruns

`ocdev task run <name> <task> --input-file <private.json> --json` accepts an object up to 1 MiB. Inputs are merged over project defaults and then recipe defaults; provided values take precedence. The engine validates types, required values, and choices. **The resulting JSON object is delivered on task stdin.** Inputs are not interpolated into command strings, passed as argument values, or automatically exported as environment variables. Write an explicit input-reading application/script when needed. Shell syntax requires an explicit shell command.

Recipe/project definitions and task input files must resolve to regular files and are limited to 1 MiB. Symlinks to regular files are accepted; FIFOs, directories, and devices are rejected. Limits apply to bytes actually read, not just the reported file size.

Registration stores an immutable recipe revision and an ID pointer in `~/.ocdev/recipes`, under private permissions and a process lock. Re-registering an ID updates its pointer. Existing environments store their resolved recipe and digest rather than re-resolving that pointer. A digest identifies recipe configuration, not all dependencies, network downloads, or seed/script content; registration is not permission to execute.

`setup --rerun` re-reads the **saved project's host seed references**, atomically replaces destination files after writing private temporary files and applying their final permissions, repeats every `afterCreate` task in order, and may start services again. It is not automatic recovery or a safe resume algorithm. Task bodies, package lifecycle scripts, migrations, downloads, and file writes can have side effects. Review before every rerun; editing the original recipe does not change an already pinned environment.

Failed setup retains the environment and records failed steps for inspection. UUID checks under the environment lock prevent attaching pinned operations to a replacement container with the same name, including ordinary start/stop, binding, and import/export commands. Rebind locks both the destination and the current binding owner, validates pinned identities, and rechecks ownership before removing a device; an ownership change fails the operation rather than switching to an unlocked owner. Deletion previews owned resources, runs `beforeDelete` hooks first, and stops on failure rather than pretending cleanup succeeded. Hooks require a running environment; start a stopped environment before deletion when hooks are declared. When an authoritative Incus query confirms the instance is already absent, `delete` reconciles only local metadata/ports and records hooks as skipped. A replacement UUID still blocks deletion; backend unavailability is not treated as absence. Source snapshots and their backing containers are not owned cleanup resources and are left untouched by ocdev's clone/delete operations. Recipe code itself is trusted and can reach granted mounts or external resources.

## Output, state, and current limits

- `--json` emits one JSON document on successful stdout. Errors exit nonzero, leave stdout empty, and emit a sanitized `{"error":{"code":...,"message":...}}` on stderr. Recorded operation failures also include `error.operationId`, usable with `runs show`. Successful recipe and JSON-mode legacy mutations include `operationId`; list responses are arrays. Failures before operation creation have no ID. Do not parse human-readable output.
- `recipe show`, recipe lists, task lists, and environment inspection expose public projections, not raw command arguments, input defaults, seed contents, or task output.
- Local environment metadata and operation records live under `~/.ocdev/environments` and `~/.ocdev/runs` with private permissions. They retain recipe configuration and host file references; do not publish these files merely because public CLI projections are sanitized.
- Task stdout/stderr is bounded during execution. Restricted task logs live under `~/.ocdev/runs/logs`; metadata contains only step/exit status and log availability. Use `runs logs <id> --tail N` explicitly (1–1000 lines). Logs redact supplied secret inputs and credential-shaped lines best-effort and remain sensitive. Capture is capped at 64 KiB per task; persisted text is capped at 16 KiB per task within a rolling 256 KiB JSON log. Truncation is reported. There is no artifact uploader.
- `services list|start|stop|restart|logs` requires a recipe process-compose configuration. `autostart: true` launches `up --detached` after setup. With autostart disabled, `services start <name>` launches the supervisor before per-process actions. Each environment uses a dedicated Unix socket; whole-stack stop/restart targets its declared processes. Logs require a service name; use `--tail` from 1 to 1000. The adapter bounds captured output and reports truncation.
- Service log retrieval is explicitly sensitive. Credential-shaped lines are filtered best-effort, but arbitrary application output can still disclose secrets. Keep redirected logs private (for example, use `umask 077`) and do not upload them without review. ocdev does not manage permissions/rotation of logs written by application or supervisor configuration.
- Container-running status, process status, and application readiness are distinct. `servicesReady`/`ready` remain `unknown`; there is no readiness engine.
- There is no daemon, automatic rerun, automatic migration of existing environments, fleet cleanup, secret manager, remote recipe download, or external resource ownership transfer. A private application pack being prepared and schema-validated is **not** evidence of live adoption or production compatibility.

## Verification

Source builds use Nim and Atlas. `make dev-setup` initializes Atlas and installs `cligen`, NimYAML, and `checksums` from the `.nimble` manifest into project-local `cmd/ocdev/deps/`. Atlas generates `nim.cfg` search paths and disables global Nimble package lookup; no global package installation is required. The resulting Linux binary has no Nim, Python, Node, or YAML-library runtime dependency. The maintained YAML parser increases binary size: the stripped implementation binary is approximately 1.2 MiB, with an explicit 2 MiB release budget in `make size-check`.

`make test` builds and runs Nim `unittest` suites and compiled Nim fake-Incus executables on Linux, with no Python dependency and no live daemon access. Each integration test has an isolated home/backend state; subprocesses have separate stdout/stderr capture, deadlines, and cleanup. The engine harness is a normal Nim source file built with the same Atlas configuration, not generated at test runtime. Coverage includes schema/registry behavior, JSON contracts, concurrent clones, failed hooks, real-shell atomic seed replacement, UUID protection, recovery, and service projections. `make test-list-json`, `make test-create-config`, `make test-exec`, and `make test-recipes` run focused subsets; all test binaries live under ignored `bin/`.

A live smoke test is separately opt-in and executes trusted recipe code:

```sh
OCDEV_LIVE_TESTS=1 \
OCDEV_TEST_RECIPE=/private/test-recipe.yaml \
OCDEV_TEST_TASK=test \
make test-live
```

Use only a prepared disposable test snapshot and harmless task; optionally set `OCDEV_TEST_SERVICES=1`. The script requests normal deletion on exit and reports failed cleanup rather than bypassing hooks. No live smoke test was run during this implementation.

## Snapshot trust and private configuration

A clone inherits snapshot files and potentially credentials, application data, host mounts, and startup behavior. Inspect and choose a trusted base before cloning. Cloning is not sanitization, and task execution is not a sandbox. ocdev leaves the source untouched but cannot prevent trusted scripts or inherited services from touching shared mounted files or external systems.

Keep real `.env` files, database URLs, tokens, application-specific scripts, and private snapshot names out of public recipes and repositories. Store private projects separately, with `0700` directories and `0600` files, and reference secret seed files rather than embedding contents. Validation does not inspect those contents. Seed delivery is local configuration transport, not encryption, credential rotation, or lifecycle ownership of an external database.
