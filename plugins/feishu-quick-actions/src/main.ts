import { access, chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import {
  definePlugin,
  servePlugin,
  type AhaKeyHost,
} from "@ahakey/plugin-sdk";

type JsonRecord = Record<string, unknown>;
type TemplateName = "dailyReport" | "meetingNotes";
type ActionName =
  | "openApp"
  | "openWeb"
  | "openDocs"
  | "pasteDailyReport"
  | "pasteMeetingNotes"
  | "openConfig";

interface FeishuConfig {
  webhookUrl: string;
  appPaths: string[];
  urls: {
    web: string;
    docs: string;
  };
  hotkeys: Record<ActionName, string | null>;
  templates: Record<TemplateName, string>;
}

interface RegisteredHotkey {
  action: ActionName;
  hotkey: string;
  token: string;
}

const configPath = process.env.AHAKEY_FEISHU_CONFIG?.trim() || join(
  homedir(),
  "Library/Application Support/AhaKeyConfig/plugin-data/dev.ahakey.feishu-quick-actions/config.json",
);

const defaultConfig: FeishuConfig = {
  webhookUrl: "",
  appPaths: [
    "/Applications/Lark.app",
    "/Applications/飞书.app",
    "/Applications/Feishu.app",
  ],
  urls: {
    web: "https://www.feishu.cn/",
    docs: "https://www.feishu.cn/drive/home",
  },
  hotkeys: {
    openApp: "ctrl+option+f",
    openWeb: null,
    openDocs: "ctrl+option+d",
    pasteDailyReport: "ctrl+option+r",
    pasteMeetingNotes: "ctrl+option+m",
    openConfig: "ctrl+option+,",
  },
  templates: {
    dailyReport: `【今日进展】
1.

【问题与风险】
1.

【明日计划】
1.`,
    meetingNotes: `【会议主题】

【时间】

【参与人】

【结论】
1.

【行动项】
- [ ] 负责人 / 截止时间`,
  },
};

const actionDescriptions: Record<ActionName, string> = {
  openApp: "打开本机飞书/Lark；未安装时打开飞书网页版",
  openWeb: "打开飞书网页版",
  openDocs: "打开飞书云文档",
  pasteDailyReport: "在当前应用粘贴日报模板",
  pasteMeetingNotes: "在当前应用粘贴会议纪要模板",
  openConfig: "打开本机私密配置文件",
};

let host: AhaKeyHost | undefined;
const registeredHotkeys = new Map<string, RegisteredHotkey>();

function requireHost(): AhaKeyHost {
  if (host === undefined) {
    throw new Error("AhaKey host is not initialized");
  }
  return host;
}

function asRecord(value: unknown, method: string): JsonRecord {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as JsonRecord;
  }
  throw new Error(`${method} expects an object parameter`);
}

function asNonEmptyString(value: unknown, field: string): string {
  if (typeof value === "string" && value.trim().length > 0) {
    return value;
  }
  throw new Error(`${field} must be a non-empty string`);
}

function optionalString(value: unknown, fallback: string): string {
  return typeof value === "string" ? value : fallback;
}

function optionalNullableString(value: unknown, fallback: string | null): string | null {
  return value === null || typeof value === "string" ? value : fallback;
}

function parseConfig(raw: unknown): FeishuConfig {
  const root = typeof raw === "object" && raw !== null && !Array.isArray(raw)
    ? raw as JsonRecord
    : {};
  const urls = typeof root.urls === "object" && root.urls !== null && !Array.isArray(root.urls)
    ? root.urls as JsonRecord
    : {};
  const hotkeys = typeof root.hotkeys === "object" && root.hotkeys !== null && !Array.isArray(root.hotkeys)
    ? root.hotkeys as JsonRecord
    : {};
  const templates = typeof root.templates === "object" && root.templates !== null && !Array.isArray(root.templates)
    ? root.templates as JsonRecord
    : {};
  const appPaths = Array.isArray(root.appPaths)
    ? root.appPaths.filter((value): value is string => typeof value === "string" && value.length > 0)
    : defaultConfig.appPaths;

  return {
    webhookUrl: optionalString(root.webhookUrl, defaultConfig.webhookUrl).trim(),
    appPaths: appPaths.length > 0 ? appPaths : defaultConfig.appPaths,
    urls: {
      web: optionalString(urls.web, defaultConfig.urls.web),
      docs: optionalString(urls.docs, defaultConfig.urls.docs),
    },
    hotkeys: {
      openApp: optionalNullableString(hotkeys.openApp, defaultConfig.hotkeys.openApp),
      openWeb: optionalNullableString(hotkeys.openWeb, defaultConfig.hotkeys.openWeb),
      openDocs: optionalNullableString(hotkeys.openDocs, defaultConfig.hotkeys.openDocs),
      pasteDailyReport: optionalNullableString(
        hotkeys.pasteDailyReport,
        defaultConfig.hotkeys.pasteDailyReport,
      ),
      pasteMeetingNotes: optionalNullableString(
        hotkeys.pasteMeetingNotes,
        defaultConfig.hotkeys.pasteMeetingNotes,
      ),
      openConfig: optionalNullableString(hotkeys.openConfig, defaultConfig.hotkeys.openConfig),
    },
    templates: {
      dailyReport: optionalString(templates.dailyReport, defaultConfig.templates.dailyReport),
      meetingNotes: optionalString(templates.meetingNotes, defaultConfig.templates.meetingNotes),
    },
  };
}

async function writeDefaultConfig(): Promise<void> {
  await mkdir(dirname(configPath), { recursive: true, mode: 0o700 });
  await writeFile(configPath, `${JSON.stringify(defaultConfig, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
    flag: "wx",
  });
}

async function loadConfig(): Promise<FeishuConfig> {
  try {
    const data = await readFile(configPath, "utf8");
    await chmod(configPath, 0o600);
    return parseConfig(JSON.parse(data));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw new Error(`无法读取飞书插件配置：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  await writeDefaultConfig();
  return structuredClone(defaultConfig);
}

async function firstInstalledApp(paths: string[]): Promise<string | null> {
  for (const path of paths) {
    try {
      await access(path);
      return path;
    } catch {
      // Try the next configured application path.
    }
  }
  return null;
}

async function openApp(): Promise<JsonRecord> {
  const connectedHost = requireHost();
  const config = await loadConfig();
  const appPath = await firstInstalledApp(config.appPaths);
  if (appPath !== null) {
    const result = await connectedHost.openPath(appPath);
    if (result.opened === true) {
      return { opened: true, via: "application", path: appPath };
    }
  }
  const result = await connectedHost.openUrl(config.urls.web);
  return { opened: result.opened === true, via: "web", url: config.urls.web };
}

async function openConfiguredUrl(key: "web" | "docs"): Promise<JsonRecord> {
  const config = await loadConfig();
  const url = config.urls[key];
  const result = await requireHost().openUrl(url);
  return { opened: result.opened === true, url };
}

async function pasteTemplate(template: TemplateName): Promise<JsonRecord> {
  const config = await loadConfig();
  const text = config.templates[template];
  const result = await requireHost().pasteText(text);
  return {
    pasted: result.pasted === true,
    template,
    characters: text.length,
  };
}

function isAllowedWebhook(rawValue: string): boolean {
  try {
    const url = new URL(rawValue);
    const allowedHosts = new Set(["open.feishu.cn", "open.larksuite.com"]);
    return url.protocol === "https:"
      && allowedHosts.has(url.hostname)
      && /^\/open-apis\/bot\/v2\/hook\/[^/]+$/.test(url.pathname);
  } catch {
    return false;
  }
}

async function sendWebhook(params: unknown): Promise<JsonRecord> {
  const input = asRecord(params, "feishu/sendWebhook");
  const text = asNonEmptyString(input.text, "text");
  const config = await loadConfig();
  if (config.webhookUrl.length === 0) {
    throw new Error(`尚未配置飞书群机器人 webhook；请编辑 ${configPath}`);
  }
  if (!isAllowedWebhook(config.webhookUrl)) {
    throw new Error("webhookUrl 必须是飞书/Lark v2 自定义机器人 HTTPS 地址");
  }

  const payload = JSON.stringify({
    msg_type: "text",
    content: { text },
  });
  if (Buffer.byteLength(payload, "utf8") > 30 * 1024) {
    throw new Error("飞书 webhook 消息超过 30 KB 安全上限");
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  timeout.unref();
  try {
    const response = await fetch(config.webhookUrl, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: payload,
      signal: controller.signal,
    });
    const responseText = await response.text();
    let responseBody: JsonRecord = {};
    if (responseText.length > 0) {
      try {
        const parsed = JSON.parse(responseText) as unknown;
        responseBody = typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
          ? parsed as JsonRecord
          : { value: parsed };
      } catch {
        responseBody = { message: responseText.slice(0, 500) };
      }
    }

    const serviceCode = typeof responseBody.code === "number"
      ? responseBody.code
      : typeof responseBody.StatusCode === "number"
        ? responseBody.StatusCode
        : 0;
    if (!response.ok || serviceCode !== 0) {
      const detail = typeof responseBody.msg === "string"
        ? responseBody.msg
        : typeof responseBody.StatusMessage === "string"
          ? responseBody.StatusMessage
          : `HTTP ${response.status}`;
      throw new Error(`飞书 webhook 发送失败：${detail}`);
    }
    return { sent: true, status: response.status, response: responseBody };
  } finally {
    clearTimeout(timeout);
  }
}

async function openConfig(): Promise<JsonRecord> {
  await loadConfig();
  const result = await requireHost().openPath(configPath);
  return { opened: result.opened === true, path: configPath };
}

async function unregisterHotkeys(): Promise<void> {
  const connectedHost = host;
  if (connectedHost === undefined) {
    registeredHotkeys.clear();
    return;
  }
  for (const registration of registeredHotkeys.values()) {
    try {
      await connectedHost.unregisterGlobalHotkey(registration.token);
    } catch {
      // The host also removes registrations when the plugin process exits.
    }
  }
  registeredHotkeys.clear();
}

async function registerConfiguredHotkeys(): Promise<RegisteredHotkey[]> {
  const connectedHost = requireHost();
  const config = await loadConfig();
  await unregisterHotkeys();

  for (const [action, configuredHotkey] of Object.entries(config.hotkeys) as Array<[
    ActionName,
    string | null,
  ]>) {
    const hotkey = configuredHotkey?.trim();
    if (!hotkey) continue;
    try {
      const result = await connectedHost.registerGlobalHotkey(
        hotkey,
        "feishu/hotkeyTriggered",
      );
      registeredHotkeys.set(result.token, { action, hotkey, token: result.token });
    } catch (error) {
      await connectedHost.log(
        `飞书快捷操作无法注册 ${hotkey}：${error instanceof Error ? error.message : String(error)}`,
        "warn",
      );
    }
  }
  return Array.from(registeredHotkeys.values());
}

async function runAction(action: ActionName): Promise<JsonRecord> {
  switch (action) {
  case "openApp": return openApp();
  case "openWeb": return openConfiguredUrl("web");
  case "openDocs": return openConfiguredUrl("docs");
  case "pasteDailyReport": return pasteTemplate("dailyReport");
  case "pasteMeetingNotes": return pasteTemplate("meetingNotes");
  case "openConfig": return openConfig();
  }
}

async function handleHotkey(params: unknown): Promise<JsonRecord> {
  const input = asRecord(params, "feishu/hotkeyTriggered");
  const token = asNonEmptyString(input.token, "token");
  const registration = registeredHotkeys.get(token);
  if (registration === undefined) {
    throw new Error("未知或已注销的飞书快捷键 token");
  }
  const result = await runAction(registration.action);
  await requireHost().log(`飞书快捷操作：${actionDescriptions[registration.action]}`);
  return { action: registration.action, ...result };
}

servePlugin(definePlugin({
  name: "飞书快捷操作",
  version: "0.1.0",
  methods: {
    "feishu/listActions": () => Object.entries(actionDescriptions).map(([id, description]) => ({
      id,
      description,
    })),
    "feishu/getStatus": async () => {
      const config = await loadConfig();
      const appPath = await firstInstalledApp(config.appPaths);
      const appInfo = await requireHost().getInfo();
      return {
        host: appInfo,
        configPath,
        appPath,
        webhookConfigured: config.webhookUrl.length > 0,
        registeredHotkeys: Array.from(registeredHotkeys.values()).map(({ action, hotkey }) => ({
          action,
          hotkey,
        })),
      };
    },
    "feishu/openApp": openApp,
    "feishu/openWeb": () => openConfiguredUrl("web"),
    "feishu/openDocs": () => openConfiguredUrl("docs"),
    "feishu/pasteTemplate": async (params) => {
      const input = asRecord(params, "feishu/pasteTemplate");
      const template = asNonEmptyString(input.template, "template");
      if (template !== "dailyReport" && template !== "meetingNotes") {
        throw new Error("template must be dailyReport or meetingNotes");
      }
      return pasteTemplate(template);
    },
    "feishu/sendWebhook": sendWebhook,
    "feishu/openConfig": openConfig,
    "feishu/reloadConfig": async () => ({
      registeredHotkeys: (await registerConfiguredHotkeys()).map(({ action, hotkey }) => ({
        action,
        hotkey,
      })),
    }),
    "feishu/hotkeyTriggered": handleHotkey,
  },
  onInitialize(_params, connectedHost) {
    host = connectedHost;
  },
  async onInitialized() {
    const registrations = await registerConfiguredHotkeys();
    await requireHost().log(`飞书快捷操作已启动，注册 ${registrations.length} 个快捷键`);
  },
  async onShutdown() {
    await unregisterHotkeys();
    await host?.log("飞书快捷操作已停止");
  },
}));
