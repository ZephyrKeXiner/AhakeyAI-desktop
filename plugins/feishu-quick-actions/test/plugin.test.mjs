import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import test from "node:test";

class PluginHarness {
  #child;
  #messages = [];
  #waiters = [];
  stderr = "";

  constructor(configPath) {
    this.#child = spawn(process.execPath, ["dist/main.js"], {
      cwd: new URL("..", import.meta.url),
      env: {
        ...process.env,
        AHAKEY_FEISHU_CONFIG: configPath,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.#child.stderr.setEncoding("utf8");
    this.#child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
    });

    const lines = createInterface({ input: this.#child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => {
      if (line.trim().length === 0) return;
      const message = JSON.parse(line);
      const waiter = this.#waiters.shift();
      if (waiter === undefined) {
        this.#messages.push(message);
      } else {
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    });
    this.#child.on("exit", (code, signal) => {
      const error = new Error(`plugin exited early: code=${code} signal=${signal}\n${this.stderr}`);
      for (const waiter of this.#waiters.splice(0)) {
        clearTimeout(waiter.timer);
        waiter.reject(error);
      }
    });
  }

  send(message) {
    this.#child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  nextMessage(timeoutMs = 3000) {
    const message = this.#messages.shift();
    if (message !== undefined) return Promise.resolve(message);
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: undefined };
      waiter.timer = setTimeout(() => {
        const index = this.#waiters.indexOf(waiter);
        if (index >= 0) this.#waiters.splice(index, 1);
        reject(new Error(`timed out waiting for plugin message\n${this.stderr}`));
      }, timeoutMs);
      this.#waiters.push(waiter);
    });
  }

  async close() {
    if (this.#child.exitCode !== null) return;
    this.#child.kill();
    await once(this.#child, "exit");
  }
}

async function callPlugin(harness, id, method, params, handleHostRequest = undefined) {
  const request = { jsonrpc: "2.0", id, method };
  if (params !== undefined) request.params = params;
  harness.send(request);

  for (;;) {
    const message = await harness.nextMessage();
    if (typeof message.method === "string" && message.method.startsWith("host/")) {
      assert.ok(handleHostRequest, `unexpected host request: ${message.method}`);
      const result = await handleHostRequest(message);
      harness.send({ jsonrpc: "2.0", id: message.id, result });
      continue;
    }
    if (message.id === id) return message;
    assert.fail(`unexpected plugin message: ${JSON.stringify(message)}`);
  }
}

test("registers quick actions and serves Feishu RPC methods", async (t) => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ahakey-feishu-plugin-"));
  const configPath = join(temporaryRoot, "config.json");
  const harness = new PluginHarness(configPath);
  t.after(async () => {
    await harness.close();
    await rm(temporaryRoot, { recursive: true, force: true });
  });

  harness.send({
    jsonrpc: "2.0",
    id: 1,
    method: "plugin/initialize",
    params: {
      host: {
        bundleID: "dev.ahakey.test",
        version: "1.2.3",
        build: "42",
        platform: "macos",
      },
      hostMethods: [
        "host/getInfo",
        "host/log",
        "host/openUrl",
        "host/openPath",
        "host/pasteText",
        "host/registerGlobalHotkey",
        "host/unregisterGlobalHotkey",
      ],
    },
  });
  const initialized = await harness.nextMessage();
  assert.equal(initialized.id, 1);
  assert.equal(initialized.result.name, "飞书快捷操作");
  assert.ok(initialized.result.methods.includes("feishu/openApp"));
  assert.ok(initialized.result.methods.includes("feishu/sendWebhook"));

  harness.send({ jsonrpc: "2.0", method: "plugin/initialized" });
  const registrations = [];
  for (;;) {
    const message = await harness.nextMessage();
    if (message.method === "host/registerGlobalHotkey") {
      registrations.push(message.params);
      harness.send({
        jsonrpc: "2.0",
        id: message.id,
        result: { token: `token-${registrations.length}` },
      });
      continue;
    }
    assert.equal(message.method, "host/log");
    assert.match(message.params.message, /注册 5 个快捷键/);
    harness.send({ jsonrpc: "2.0", id: message.id, result: null });
    break;
  }
  assert.deepEqual(
    registrations.map((item) => item.hotkey),
    ["ctrl+option+f", "ctrl+option+d", "ctrl+option+r", "ctrl+option+m", "ctrl+option+,"],
  );
  assert.ok(registrations.every((item) => item.callbackMethod === "feishu/hotkeyTriggered"));

  const storedConfig = JSON.parse(await readFile(configPath, "utf8"));
  assert.equal(storedConfig.webhookUrl, "");
  assert.equal((await stat(configPath)).mode & 0o777, 0o600);

  const actions = await callPlugin(harness, 2, "feishu/listActions");
  assert.equal(actions.result.length, 6);

  const status = await callPlugin(
    harness,
    3,
    "feishu/getStatus",
    undefined,
    (message) => {
      assert.equal(message.method, "host/getInfo");
      return {
        bundleID: "dev.ahakey.test",
        version: "1.2.3",
        build: "42",
        platform: "macos",
      };
    },
  );
  assert.equal(status.result.webhookConfigured, false);
  assert.equal(status.result.registeredHotkeys.length, 5);
  assert.equal(status.result.configPath, configPath);

  const docs = await callPlugin(
    harness,
    4,
    "feishu/openDocs",
    undefined,
    (message) => {
      assert.equal(message.method, "host/openUrl");
      assert.equal(message.params.url, "https://www.feishu.cn/drive/home");
      return { opened: true };
    },
  );
  assert.deepEqual(docs.result, {
    opened: true,
    url: "https://www.feishu.cn/drive/home",
  });

  const pasted = await callPlugin(
    harness,
    5,
    "feishu/pasteTemplate",
    { template: "meetingNotes" },
    (message) => {
      assert.equal(message.method, "host/pasteText");
      assert.match(message.params.text, /【行动项】/);
      return { pasted: true };
    },
  );
  assert.equal(pasted.result.pasted, true);
  assert.equal(pasted.result.template, "meetingNotes");

  const webhook = await callPlugin(
    harness,
    6,
    "feishu/sendWebhook",
    { text: "测试消息" },
  );
  assert.equal(webhook.error.code, -32603);
  assert.match(webhook.error.message, /尚未配置飞书群机器人 webhook/);

  storedConfig.webhookUrl = "https://example.com/not-a-feishu-webhook";
  await writeFile(configPath, `${JSON.stringify(storedConfig, null, 2)}\n`);
  const invalidWebhook = await callPlugin(
    harness,
    7,
    "feishu/sendWebhook",
    { text: "测试消息" },
  );
  assert.equal(invalidWebhook.error.code, -32603);
  assert.match(invalidWebhook.error.message, /必须是飞书\/Lark v2/);

  storedConfig.webhookUrl = "https://open.feishu.cn/open-apis/bot/v2/hook/test-only";
  await writeFile(configPath, `${JSON.stringify(storedConfig, null, 2)}\n`);
  const oversizedWebhook = await callPlugin(
    harness,
    8,
    "feishu/sendWebhook",
    { text: "A".repeat(31 * 1024) },
  );
  assert.equal(oversizedWebhook.error.code, -32603);
  assert.match(oversizedWebhook.error.message, /超过 30 KB/);

  harness.send({ jsonrpc: "2.0", id: 9, method: "plugin/shutdown" });
  let unregisterCount = 0;
  for (;;) {
    const message = await harness.nextMessage();
    if (message.method === "host/unregisterGlobalHotkey") {
      unregisterCount += 1;
      harness.send({ jsonrpc: "2.0", id: message.id, result: { unregistered: true } });
      continue;
    }
    if (message.method === "host/log") {
      harness.send({ jsonrpc: "2.0", id: message.id, result: null });
      continue;
    }
    assert.equal(message.id, 9);
    assert.equal(message.result, null);
    break;
  }
  assert.equal(unregisterCount, 5);
});
