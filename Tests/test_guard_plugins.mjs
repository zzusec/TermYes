// Run installed plugin code with mocked host APIs. No agent, shell command, or network request runs.
import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { stripTypeScriptTypes, syncBuiltinESMExports } from "node:module";
import { mkdtemp, readFile, writeFile, rm, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const home = await realpath(await mkdtemp(path.join(tmpdir(), "termosaic-plugin-test-")));
const realSpawn = childProcess.spawnSync;
const env = { ...process.env, PYTHONDONTWRITEBYTECODE: "1", DANGER_GUARD_SILENT: "1", DANGER_GUARD_ASK: "0" };
let count = 0;
function check(value, message) { assert.ok(value, message); count++; }
try {
	for (const client of ["pi", "opencode"]) {
		const result = realSpawn("/usr/bin/python3", ["-B", path.join(root, "AgentGuard/manage.py"), "install", client, "--home", home], { env, encoding: "utf8" });
		assert.equal(result.status, 0, result.stderr);
	}
	const plugin = await import(pathToFileURL(path.join(home, ".config/opencode/plugin/bypass-yes-opencode.js")));
	check(typeof plugin.default?.id === "string" && plugin.default.id.length > 0,
		"OpenCode v2 exports a default definition with an id");
	check(typeof plugin.default.setup === "function", "OpenCode v2 has an async setup function");
	check(plugin.BypassYesGuard === undefined, "OpenCode does not retain the old named factory");
	const originalCalls = [];
	const toolResult = { output: { status: "completed", output: "classified, not executed" },
		content: [{ type: "text", text: "classified, not executed" }], metadata: { status: "completed" } };
	let toolFailure;
	const shell = { id: "shell", name: "shell", options: { codemode: false },
		async execute(input, context) {
			originalCalls.push({ input, context });
			if (toolFailure) throw toolFailure;
			return toolResult;
		} };
	const readTool = { id: "read", execute: async () => "non-shell tool" };
	const originalRead = readTool.execute;
	const shellOptions = shell.options;
	let transforms = 0;
	let updated = 0;
	let transformFinished = false;
	await plugin.default.setup({
		location: { directory: root, project: "test-project" },
		tool: {
			async transform(callback) {
				transforms++;
				callback({
					update(id, mutate) {
						assert.equal(id, "shell", "v2 uses shell, not the old bash tool name");
						updated++;
						// The real v2 registry mutates the definition; callback return is ignored.
						mutate(shell);
					},
				});
				await Promise.resolve();
				transformFinished = true;
				return { dispose() {} };
			},
		},
	});
	check(transforms === 1 && updated === 1 && transformFinished, "setup awaits the v2 tool transform");
	check(shell.options === shellOptions && readTool.execute === originalRead,
		"only shell execute is wrapped; other tools and native permission options are unchanged");
	check(await readTool.execute() === "non-shell tool", "non-shell tools remain untouched");
	const bridgeCalls = [];
	const runBridge = (command, args, options) => {
		bridgeCalls.push({ command, args, options });
		return realSpawn(command, args, { ...options, env });
	};
	childProcess.spawnSync = runBridge;
	syncBuiltinESMExports();
	// OpenCode v2 execute gets (input, context), not (event, output.args).
	const input = { command: "git status", description: "safe classifier input", timeout: 1000, background: false };
	const context = { sessionID: "session-test", messageID: "message-test", id: "call-test", agent: "build",
		signal: new AbortController().signal, progress() {} };
	check(await shell.execute(input, context) === toolResult, "safe shell returns the original v2 result unchanged");
	check(originalCalls.length === 1 && originalCalls[0].input === input && originalCalls[0].context === context,
		"the original execute receives the exact input and context objects");
	check(bridgeCalls[0].command === "/usr/bin/python3"
		&& bridgeCalls[0].args[0] === path.join(home, ".config/opencode/hooks/termosaic/opencode/danger-guard-pi.py"),
		"the bridge path is relative to the installed plugin");
	assert.deepEqual(JSON.parse(bridgeCalls[0].args[1]), { command: "git status", cwd: root }); count++;
	check(bridgeCalls[0].options.timeout === 8000 && bridgeCalls[0].options.maxBuffer === 1024 * 1024
		&& bridgeCalls[0].options.encoding === "utf8", "the bounded synchronous bridge is preserved");
	for (const workdir of [home, "AgentGuard"]) {
		const callInput = { ...input, workdir };
		await shell.execute(callInput, context);
		assert.deepEqual(JSON.parse(bridgeCalls.at(-1).args[1]),
			{ command: "git status", cwd: path.resolve(root, workdir) }); count++;
	}
	const rejectWithoutExecution = async (callInput, pattern = /命令守卫/) => {
		const previous = originalCalls.length;
		await assert.rejects(shell.execute(callInput, context), pattern);
		assert.equal(originalCalls.length, previous, "a rejected bridge must never invoke the original execute");
		count++;
	};
	for (const command of ["git reset --hard HEAD", "rm -rf /", "", "  ", null, 42]) {
		await rejectWithoutExecution({ command });
	}
	await rejectWithoutExecution(undefined);
	for (const result of [null, { status: 1 }, { status: null, error: new Error("timeout") },
		{ status: 0, error: new Error("bridge failure"), stdout: '{"level":"safe"}' },
		{ status: 0, signal: "SIGTERM", stdout: '{"level":"safe"}' },
		{ status: 0, stdout: "" }, { status: 0, stdout: "bad-json" },
		{ status: 0, stdout: "null" }, { status: 0, stdout: '[]' },
		{ status: 0, stdout: '{"level":"allowlist"}' }, { status: 0, stdout: '{"level":"warn"}' },
		{ status: 0, stdout: '{"level":"block","reason":"test denial"}' }]) {
		childProcess.spawnSync = () => result;
		syncBuiltinESMExports();
		await rejectWithoutExecution(input);
	}
	childProcess.spawnSync = () => { throw new Error("bridge failed"); };
	syncBuiltinESMExports();
	await rejectWithoutExecution(input);
	childProcess.spawnSync = runBridge;
	syncBuiltinESMExports();
	toolFailure = new Error("native execute failure");
	await assert.rejects(shell.execute(input, context), error => error === toolFailure); count++;
	toolFailure = undefined;

	// A daemon plugin only inherits the daemon's process env. A CLI caller's
	// extra env is not part of v2 execute input/context and is not fabricated here.
	childProcess.spawnSync = (command, args, options) => {
		check(!Object.hasOwn(options, "env"), "Python inherits the host daemon env, not tool/caller-supplied env");
		const daemonEnv = { ...env };
		delete daemonEnv.TERMYES_GUARD_PROBE_TOKEN;
		delete daemonEnv.TERMYES_GUARD_PROBE_RECEIPT;
		return realSpawn(command, args, { ...options, env: daemonEnv });
	};
	syncBuiltinESMExports();
	const probeToken = "a".repeat(32); // Synthetic guard probe marker, not a credential.
	const probeCommand = `/usr/bin/printf %s ${probeToken} > /tmp/termyes-guard-executed-${probeToken}`;
	check(await shell.execute({ command: probeCommand }, context) === toolResult,
		"an active daemon guard without probe env still permits a safe probe command; missing receipt is not a load test");
	childProcess.spawnSync = realSpawn;
	syncBuiltinESMExports();

	// Only the pi SDK's tool-name helper is substituted. Strip types using existing Node.
	const piDir = path.join(home, ".pi/agent/extensions");
	let piSource = stripTypeScriptTypes(await readFile(path.join(piDir, "bypass-yes-guard.ts"), "utf8"));
	piSource = piSource.replace('import { isToolCallEventType } from "@earendil-works/pi-coding-agent";',
		'const isToolCallEventType = (name, event) => event.toolName === name;');
	await writeFile(path.join(piDir, "guard-test.mjs"), piSource);
	const piModule = await import(pathToFileURL(path.join(piDir, "guard-test.mjs")));
	let handler;
	const api = {
		on(event, callback) { assert.equal(event, "tool_call"); handler = callback; },
		exec(command, args, options) {
			const result = realSpawn(command, args, { ...options, encoding: "utf8", env });
			return { code: result.status, stdout: result.stdout };
		},
	};
	piModule.default(api);
	const event = command => ({ toolName: "bash", input: { command } });
	const ctx = { cwd: root, hasUI: true, ui: { confirm() { throw new Error("Must not prompt"); } } };
	check(await handler({ toolName: "read" }, ctx) === undefined, "pi skips non-shell tools");
	check(await handler(event("git status"), ctx) === undefined, "pi permits normal calls");
	for (const command of ["git reset --hard HEAD", "rm -rf /", ""]) {
		check((await handler(event(command), ctx)).block === true, "pi blocks dangerous/invalid input");
	}
	for (const result of [null, { code: 1 }, { code: 0, stdout: "" }, { code: 0, stdout: "bad-json" },
		{ code: 0, stdout: "null" }, { code: 0, stdout: '{"level":"allowlist"}' },
		{ code: 0, stdout: '{"level":"warn"}' }]) {
		api.exec = async () => result;
		check((await handler(event("git status"), ctx)).block === true, "pi blocks bridge failure/unknown output");
	}
	api.exec = async () => { throw new Error("timeout"); };
	check((await handler(event("git status"), ctx)).block === true, "pi blocks bridge timeout");
	console.log(`Plugin checks passed: ${count}; host APIs mocked, no real-client validation.`);
} finally {
	childProcess.spawnSync = realSpawn;
	syncBuiltinESMExports();
	await rm(home, { recursive: true, force: true });
}
