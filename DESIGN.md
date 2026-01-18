Here’s an updated version of the design doc with the extra bits you asked for:
	•	explicit UID 107 handling
	•	rebuild triggers (on-demand + suggested when .devcontainer changes)
	•	ensuring a single devcontainer per workspace + not letting users accidentally re-run the init script in a harmful way

You can just replace the previous README with this one (or splice the new sections in).

⸻

Codespace-like Workspace Runtime Using Coder + Devcontainers

Overview

This document describes how to implement a Codespaces-style developer environment using:
	•	Coder as workspace control plane
	•	Devcontainer as user workspace runtime
	•	code-server running inside the devcontainer
	•	coder-agent running inside the devcontainer
	•	codespace-host running outside the devcontainer (LinuxKit/KubeVirt) to orchestrate builds/rebuilds
	•	Devcontainer build + rebuild semantics via devcontainer CLI
	•	Build logs surfaced into Coder

This architecture presents a similar UX to GitHub Codespaces while preserving a strict secret boundary between host + user environments.

⸻

High-level Architecture

 ┌────────────────────────────────────────────┐
 │ KubeVirt VM (LinuxKit)                     │
 │────────────────────────────────────────────│
 │ services:                                  │
 │   • dockerd                                │
 │   • codespace-host (workspace orchestrator)│
 │────────────────────────────────────────────│
 │ devcontainer launched via Docker:          │
 │   • user tools / runtimes                  │
 │   • user repo mounted at /workspaces       │
 │   • code-server (IDE backend)              │
 │   • coder-agent (workspace agent)          │
 └────────────────────────────────────────────┘

Trust Model

Component	Runs in	Trust	Notes
codespace-host	host VM	trusted	orchestrates devcontainer build + lifecycle
coder-agent	devcontainer	workspace-scoped	exposes APIs, apps, logs
code-server	devcontainer	workspace-scoped	IDE
user workloads	devcontainer	untrusted	user code, terminals, shells
host secrets	host VM	never in devcontainer	
workspace token	devcontainer	OK	used by agent only


⸻

User Identity & UID 107

The workspace filesystem is shared into the VM via virtiofs and ultimately mounted into the devcontainer at /workspaces. To avoid permissions hell and keep things consistent:
	•	The virtiofs mapping uses UID/GID 107:107 for workspace files.
	•	The devcontainer must run as UID 107 so that:
	•	tools (git, language servers, build tools) can read/write the repo
	•	.vscode, .venv, node_modules, etc. are created with correct ownership
	•	The host (codespace-host) should avoid doing anything as root that leaves files owned by 0:0 in /workspaces.

Policy
	1.	Host Git operations as 107
After cloning or updating the repo on the host, ensure ownership:

chown -R 107:107 "${REPO_DIR}"

Alternatively, run git as 107 (e.g. sudo -u dev git ... inside the workspace container if you have a dev user there).

	2.	Devcontainer runs as UID 107
When starting the devcontainer:

docker run \
  --user 107:107 \
  -v "${REPO_DIR}:/workspaces:cached" \
  ...

That keeps file ownership consistent with the virtiofs mapping.

	3.	Workspace-init script assumes non-root
Inside the devcontainer, workspace-init.sh should avoid doing anything that requires root (or at least degrade gracefully) where possible. If it needs to install binaries (code-server, agent), it can:
	•	try /usr/local/bin if permitted
	•	otherwise fall back to $HOME/.local/bin and prepend to PATH

This gives you a stable, predictable identity model: everything in /workspaces is owned by 107, and the devcontainer process runs as 107.

⸻

Bootstrap Sequence (Cold Start)
	1.	VM Boot
	•	LinuxKit starts
	•	dockerd and codespace-host services come up
	•	virtiofs mounts /workspaces + /run/config
	2.	codespace-host initialization
	•	reads repo + workspace metadata from /run/config
	•	clones/fetches repo into /workspaces/repo
	•	ensures /workspaces/repo is owned by UID 107
	•	checks .devcontainer/ for custom config
	•	selects devcontainer image or triggers build with devcontainer CLI
	3.	Devcontainer Build
	•	devcontainer build --workspace-folder /workspaces/repo --image-name devcontainer-<ws-id>:<tag>
	•	build logs streamed to stdout/stderr and captured by Coder
	4.	Devcontainer Run
	•	Host runs devcontainer via Docker:
	•	mounts /workspaces/repo → /workspaces
	•	mounts /opt/codespace-host/init → /opt/codespace-init:ro
	•	sets --user 107:107
	•	overrides entrypoint to /opt/codespace-init/workspace-init.sh
	•	injects CODER_AGENT_TOKEN, CODER_AGENT_URL, CODE_SERVER_PORT, etc.
	5.	Inside Devcontainer
workspace-init.sh:
	•	validates /workspaces and UID/GID
	•	ensures code-server is available (install if needed)
	•	ensures coder-agent binary is available (install if needed)
	•	starts code-server on localhost:<PORT> (background)
	•	starts coder-agent (foreground) pointing at /workspaces
	6.	User Connects
Browser ↔ Coder ↔ agent ↔ code-server.

⸻

Rebuild Triggers & Workflow

Rebuilds are handled in two ways:
	1.	On-demand rebuilds – user explicitly asks for a rebuild via the UI/CLI.
	2.	Suggested rebuilds – Coder suggests a rebuild when .devcontainer changes (similar to VS Code).

1. On-demand Rebuild

On-demand rebuild is the canonical “Rebuild devcontainer” action.

Trigger:
	•	User clicks a “Rebuild devcontainer” button in Coder UI, or
	•	CLI/API call to a “rebuild” endpoint per workspace.

Host-side flow (codespace-host):
	1.	Stop existing devcontainer

docker rm -f "devcontainer-${WORKSPACE_ID}" || true


	2.	Sync repo
	•	git fetch / reset in /workspaces/repo
	•	chown -R 107:107 /workspaces/repo
	3.	Compute devcontainer image tag
	•	Default: devcontainer-${WORKSPACE_ID}:latest
	•	Later: incorporate a hash of .devcontainer/** into tag to avoid rebuilds when unchanged.
	4.	Rebuild devcontainer image (if needed)
	•	devcontainer build --workspace-folder /workspaces/repo --image-name devcontainer-<ws-id>:<tag>
	•	All logs → stdout/stderr for Coder to surface as build logs.
	5.	Run devcontainer
Same as cold start: docker run with mounts, entrypoint override, --user 107:107, envs.

The user sees:
	•	workspace goes into “rebuilding” state,
	•	build logs streaming (from devcontainer CLI),
	•	workspace returns with new image and agent connected.

2. Suggested Rebuilds (VS Code-style)

We also want “you changed devcontainer config, consider rebuilding” hints, rather than silently ignoring changes.

Detecting changes:
	•	The devcontainer definition lives under .devcontainer/** in the repo.
	•	Inside the devcontainer, the coder-agent (or a sidecar process) can watch for:
	•	devcontainer.json
	•	.devcontainer/Dockerfile
	•	other relevant files (e.g. .devcontainer/*.json, features.json)

Example strategy:
	•	A lightweight file watcher in the devcontainer (or agent extension) observes changes under .devcontainer/**.
	•	On change:
	•	it emits a workspace event to Coder, e.g. devcontainer_config_changed.

User-facing UX:
	•	Coder UI shows a banner or notification:
“Devcontainer configuration changed. Rebuild to apply changes?”
	•	User can click:
	•	Rebuild now → triggers on-demand rebuild flow
	•	Ignore → event cleared; no rebuild

Important:
	•	Suggested rebuild never automatically rebuilds.
It only nudges the user, exactly like VS Code: config changes are not applied until rebuild.

⸻

Single Devcontainer Instance per Workspace

We want to avoid:
	•	multiple devcontainer containers for the same workspace ID, and
	•	users accidentally re-running the init script inside the devcontainer and spawning duplicate code-server/agent processes.

Host-level Guarantee: One Container per Workspace

codespace-host enforces exactly one running devcontainer per workspace ID:
	•	container name is deterministic: devcontainer-${WORKSPACE_ID}
	•	before starting a devcontainer, host always does:

docker rm -f "devcontainer-${WORKSPACE_ID}" >/dev/null 2>&1 || true


	•	there is no user-accessible path that directly calls docker run inside the LinuxKit VM.

So regardless of rebuilds or restarts, you never have two devcontainers concurrently for the same workspace.

Devcontainer-level Safety: Idempotent workspace-init

Inside the devcontainer, the user technically could run /opt/codespace-init/workspace-init.sh manually (they’re in the same container), which would try to start a second code-server + agent.

We make the script idempotent and defensive:
	•	On start, workspace-init.sh checks for running processes:
	•	If a code-server is already bound to ${CODE_SERVER_PORT} → log and skip starting another.
	•	If a coder-agent tied to this workspace is already running → log and exit instead of spawning a duplicate.
	•	It can also record an “init lockfile”, e.g. /tmp/workspace-init.lock:
	•	first run creates it and writes the main agent PID
	•	subsequent calls detect the lock and either:
	•	exit with a warning, or
	•	validate the PID and only re-init if the original agent is gone.

Example behaviour:

[devcontainer] workspace-init starting...
[devcontainer] Detected existing agent (PID=123) – refusing to start a second agent.
[devcontainer] If you believe this is stale, restart the devcontainer from the UI.

That gives you:
	•	Host guarantees only one container per workspace.
	•	Init script guarantees only one agent/code-server pair per container, and makes it obvious to the user that the right way to “fix things” is to restart/rebuild from the platform, not manually spam the init script.

⸻

Code-server Run Model
	•	Runs inside the devcontainer
	•	Managed by workspace-init, not by the image’s default entrypoint
	•	Start order inside devcontainer:
	1.	workspace-init.sh (as entrypoint)
	2.	ensure_code_server (install if missing)
	3.	ensure_coder_agent
	4.	start_code_server (background)
	5.	start_coder_agent (foreground exec)
	•	Exposed to users via a coder_app:

resource "coder_app" "code" {
  agent_id     = coder_agent.dev.id
  display_name = "VS Code"
  url          = "http://localhost:13337/?folder=/workspaces"
}



⸻

Build Logs in Coder

Because all heavy lifting happens on the host:
	•	devcontainer CLI build logs (stdout/stderr) are:
	•	streamed by codespace-host
	•	visible as workspace build logs in Coder UI
	•	devcontainer runtime logs (agent + workspace-init + code-server) are:
	•	visible via agent logs in Coder
	•	optionally viewable via docker logs devcontainer-<ws-id> for deeper debugging

This mimics Envbuilder’s UX: a single place in the UI to see “what happened during build / startup”.

⸻

Comparison to Codespaces / Dev Containers Extension

This design diverges slightly from “pure” devcontainers:
	•	You use devcontainer CLI for builds, but you:
	•	run containers manually with docker run
	•	override entrypoint with your own workspace-init.sh
	•	inject agent + code-server at runtime

That’s intentional, to:
	•	keep the host/devcontainer trust boundary clean
	•	ensure Coder remains the authority for:
	•	agent lifecycle
	•	apps
	•	rebuilds
	•	workspace identity + tokens

On top, you still get “rebuild when config changes” semantics via the suggested rebuild flow, very similar to VS Code’s “Rebuild container” prompt.
