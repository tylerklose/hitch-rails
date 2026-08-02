import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import {createRequire} from "node:module";
import {randomBytes} from "node:crypto";

import {
  Client,
  InsufficientScopeError,
  StreamableHTTPClientTransport,
  UnauthorizedError
} from "@modelcontextprotocol/client";

const PROTOCOL_VERSION = "2026-07-28";
const BROWSER_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36";
const AUTHORIZATION_PARAMETER_NAMES = [
  "client_id",
  "code_challenge",
  "code_challenge_method",
  "redirect_uri",
  "resource",
  "response_type",
  "scope",
  "state"
];

function fail(message) {
  throw new Error(`Hitch TypeScript client smoke: ${message}`);
}

function loadConfig(inputPath) {
  const stat = fs.lstatSync(inputPath);
  if (!stat.isFile() || stat.isSymbolicLink()) fail("credential input must be a regular non-symlink file");
  const mode = stat.mode & 0o777;
  if (mode !== 0o600) fail("credential input must be mode 0600");

  const config = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  for (const key of ["scenario", "endpoint", "issuer", "redirect_uri", "client_id", "auth_method"]) {
    if (typeof config[key] !== "string" || config[key].length === 0) fail(`missing ${key}`);
  }
  if (config.auth_method === "client_secret_basic" &&
      (typeof config.client_secret !== "string" || config.client_secret.length === 0)) {
    fail("confidential client secret is missing");
  }
  if (config.auth_method === "none" && config.client_secret !== null) {
    fail("public client unexpectedly received a secret");
  }
  if (!["none", "client_secret_basic"].includes(config.auth_method)) {
    fail("unsupported token endpoint authentication method");
  }

  const endpoint = new URL(config.endpoint);
  const issuer = new URL(config.issuer);
  const redirect = new URL(config.redirect_uri);
  if (endpoint.protocol !== "http:" || endpoint.hostname !== "127.0.0.1" ||
      endpoint.pathname !== "/mcp" || endpoint.search || endpoint.hash) {
    fail("M5.4 endpoint must be the exact loopback HTTP /mcp resource");
  }
  if (issuer.origin !== endpoint.origin || !["", "/"].includes(issuer.pathname) ||
      issuer.search || issuer.hash || issuer.username || issuer.password) {
    fail("issuer must be the endpoint origin");
  }
  if (redirect.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(redirect.hostname) ||
      !redirect.pathname.startsWith("/callback/") || redirect.search || redirect.hash ||
      redirect.username || redirect.password) {
    fail("redirect URI must be a clean loopback HTTP callback");
  }

  return config;
}

function installedSdkVersion() {
  const require = createRequire(import.meta.url);
  const entry = require.resolve("@modelcontextprotocol/client");
  let directory = path.dirname(entry);
  while (directory !== path.dirname(directory)) {
    const candidate = path.join(directory, "package.json");
    if (fs.existsSync(candidate)) {
      const manifest = JSON.parse(fs.readFileSync(candidate, "utf8"));
      if (manifest.name === "@modelcontextprotocol/client") return manifest.version;
    }
    directory = path.dirname(directory);
  }
  fail("could not resolve the installed SDK manifest");
}

function decodeHtmlAttribute(value) {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function encodeHtmlText(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function parseAttributes(tag) {
  const attributes = new Map();
  const pattern = /([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  for (const match of tag.matchAll(pattern)) {
    const name = match[1].toLowerCase();
    if (attributes.has(name)) fail(`consent form repeated the ${name} attribute`);
    attributes.set(name, decodeHtmlAttribute(match[2] ?? match[3] ?? ""));
  }
  return attributes;
}

function parseConsentForm(document) {
  const forms = [...document.matchAll(/<form\b([^>]*)>([\s\S]*?)<\/form>/gi)];
  if (forms.length !== 1) fail(`consent screen rendered ${forms.length} forms`);

  const attributes = parseAttributes(forms[0][1]);
  const fields = new Map();
  for (const match of forms[0][2].matchAll(/<input\b[^>]*>/gi)) {
    const input = parseAttributes(match[0]);
    if ((input.get("type") ?? "text").toLowerCase() !== "hidden") continue;
    const name = input.get("name");
    if (!name) continue;
    if (fields.has(name)) fail(`consent form repeated the ${name} field`);
    fields.set(name, input.get("value") ?? "");
  }

  return {
    action: attributes.get("action"),
    method: (attributes.get("method") ?? "get").toLowerCase(),
    fields
  };
}

function assertUniqueParameters(parameters, label) {
  const names = [...parameters.keys()];
  if (new Set(names).size !== names.length) fail(`${label} repeated an OAuth parameter`);
}

function expectedResourceMetadataUrl(endpoint) {
  const resource = new URL(endpoint);
  return new URL(`/.well-known/oauth-protected-resource${resource.pathname}`, resource.origin).href;
}

function challengeField(challenge, name) {
  const match = challenge.match(new RegExp(`(?:^|[,\\s])${name}="([^"]*)"`));
  return match?.[1];
}

function assertBearerChallenge(challenge, expected) {
  if (typeof challenge !== "string" || !challenge.match(/^Bearer(?:\s|$)/i)) {
    fail("MCP response omitted its Bearer challenge");
  }
  if (challengeField(challenge, "scope")?.split(/\s+/).sort().join(" ") !== expected.scope) {
    fail("MCP challenge scope drifted");
  }
  if (challengeField(challenge, "resource_metadata") !== expected.resourceMetadata) {
    fail("MCP challenge resource_metadata drifted");
  }
  if (challengeField(challenge, "error") !== expected.error) {
    fail("MCP challenge error drifted");
  }
}

class WireObservations {
  constructor(config) {
    this.endpoint = new URL(config.endpoint).href;
    this.unauthorizedChallenges = [];
    this.insufficientScopeChallenges = [];
  }

  async fetch(input, init) {
    const requestUrl = input instanceof Request ? input.url : new URL(input).href;
    const method = (input instanceof Request ? input.method : init?.method ?? "GET").toUpperCase();
    const response = await fetch(input, init);
    if (requestUrl === this.endpoint && method === "POST") {
      const challenge = response.headers.get("www-authenticate");
      if (response.status === 401) this.unauthorizedChallenges.push(challenge);
      if (response.status === 403) this.insufficientScopeChallenges.push(challenge);
    }
    return response;
  }
}

class HitchOAuthProvider {
  constructor(config) {
    this.config = config;
    this.savedTokens = undefined;
    this.savedVerifier = undefined;
    this.savedDiscovery = undefined;
    this.pendingCallback = undefined;
    this.authorizationScopes = [];
    this.expectedState = undefined;
  }

  get redirectUrl() {
    return this.config.redirect_uri;
  }

  get clientMetadata() {
    return {
      redirect_uris: [this.config.redirect_uri],
      token_endpoint_auth_method: this.config.auth_method,
      grant_types: ["authorization_code"],
      response_types: ["code"],
      client_name: `Hitch ${this.config.scenario}`
    };
  }

  state() {
    this.expectedState = randomBytes(32).toString("base64url");
    return this.expectedState;
  }

  assertIssuerContext(context) {
    if (context?.issuer && context.issuer !== this.config.issuer) {
      fail("SDK requested credentials for an unexpected authorization server");
    }
  }

  clientInformation(context) {
    this.assertIssuerContext(context);
    return {
      client_id: this.config.client_id,
      client_secret: this.config.client_secret ?? undefined,
      token_endpoint_auth_method: this.config.auth_method,
      redirect_uris: [this.config.redirect_uri],
      grant_types: ["authorization_code"],
      response_types: ["code"],
      scope: "mcp admin",
      issuer: this.config.issuer
    };
  }

  tokens(context) {
    this.assertIssuerContext(context);
    return this.savedTokens;
  }

  saveTokens(tokens, context) {
    this.assertIssuerContext(context);
    this.savedTokens = tokens;
  }

  saveCodeVerifier(verifier) {
    this.savedVerifier = verifier;
  }

  codeVerifier() {
    if (!this.savedVerifier) fail("SDK requested a missing PKCE verifier");
    return this.savedVerifier;
  }

  saveDiscoveryState(state) {
    this.savedDiscovery = state;
  }

  discoveryState() {
    return this.savedDiscovery;
  }

  invalidateCredentials(scope) {
    if (scope === "all" || scope === "tokens") this.savedTokens = undefined;
    if (scope === "all" || scope === "verifier") this.savedVerifier = undefined;
    if (scope === "all" || scope === "discovery") this.savedDiscovery = undefined;
  }

  async redirectToAuthorization(authorizationUrl) {
    const url = new URL(authorizationUrl);
    if (url.origin !== new URL(this.config.issuer).origin || url.pathname !== "/oauth/authorize") {
      fail("SDK redirected to an unexpected authorization endpoint");
    }
    assertUniqueParameters(url.searchParams, "authorization request");
    const names = [...url.searchParams.keys()].sort();
    if (JSON.stringify(names) !== JSON.stringify(AUTHORIZATION_PARAMETER_NAMES)) {
      fail(`authorization parameter set drifted: ${names.join(",")}`);
    }
    if (url.searchParams.get("response_type") !== "code" ||
        url.searchParams.get("client_id") !== this.config.client_id ||
        url.searchParams.get("redirect_uri") !== this.config.redirect_uri ||
        url.searchParams.get("resource") !== new URL(this.config.endpoint).href ||
        url.searchParams.get("code_challenge_method") !== "S256" ||
        !url.searchParams.get("code_challenge")?.match(/^[A-Za-z0-9_-]{43}$/) ||
        url.searchParams.get("state") !== this.expectedState) {
      fail("authorization request security parameters drifted");
    }
    const scope = url.searchParams.get("scope");
    if (!scope) fail("authorization request omitted scope");
    const normalizedScope = scope.split(/\s+/).sort().join(" ");
    const expectedScope = this.authorizationScopes.length === 0 ? "mcp" : "admin mcp";
    if (normalizedScope !== expectedScope) fail(`authorization scope drifted: ${normalizedScope}`);
    this.authorizationScopes.push(normalizedScope);

    const consent = await fetch(url, {
      headers: {"user-agent": BROWSER_USER_AGENT},
      redirect: "manual"
    });
    if (consent.status !== 200) fail(`consent screen returned ${consent.status}`);
    const document = await consent.text();
    const form = parseConsentForm(document);
    if (form.method !== "post" || !form.action) fail("consent screen omitted its POST form action");
    const action = new URL(form.action, url);
    if (action.origin !== url.origin || action.pathname !== url.pathname || action.search || action.hash) {
      fail("consent form action drifted");
    }
    if (!form.fields.get("authenticity_token")) fail("consent screen omitted the CSRF token");
    for (const name of AUTHORIZATION_PARAMETER_NAMES) {
      if (form.fields.get(name) !== url.searchParams.get(name)) {
        fail(`consent form changed the ${name} parameter`);
      }
    }
    for (const grantedScope of scope.split(/\s+/)) {
      if (!document.includes(`<code>${encodeHtmlText(grantedScope)}</code>`)) {
        fail(`consent screen did not display the ${grantedScope} scope`);
      }
    }
    const resource = url.searchParams.get("resource");
    if (!document.includes(`<code>${encodeHtmlText(resource)}</code>`)) {
      fail("consent screen did not display the target resource");
    }
    const setCookies = typeof consent.headers.getSetCookie === "function"
      ? consent.headers.getSetCookie()
      : [consent.headers.get("set-cookie")].filter(Boolean);
    const cookie = setCookies.map((value) => value.split(";", 1)[0]).join("; ");
    if (!cookie) fail("consent screen omitted the session cookie");

    const approval = new URLSearchParams(form.fields);
    const response = await fetch(action, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "cookie": cookie,
        "user-agent": BROWSER_USER_AGENT
      },
      body: approval,
      redirect: "manual"
    });
    if (![302, 303].includes(response.status)) {
      fail(`authorization endpoint returned ${response.status}`);
    }

    const location = response.headers.get("location");
    if (!location) fail("authorization response omitted Location");
    const callback = new URL(location);
    const expected = new URL(this.config.redirect_uri);
    if (callback.origin !== expected.origin || callback.pathname !== expected.pathname) {
      fail("authorization response targeted an unregistered redirect");
    }
    if (callback.searchParams.get("state") !== this.expectedState) {
      fail("authorization response state mismatch");
    }
    if (!callback.searchParams.get("code")) fail("authorization response omitted code");
    if (callback.searchParams.get("iss") !== this.config.issuer) {
      fail("authorization response issuer mismatch");
    }
    assertUniqueParameters(callback.searchParams, "authorization response");
    const callbackNames = [...callback.searchParams.keys()].sort();
    if (JSON.stringify(callbackNames) !== JSON.stringify(["code", "iss", "state"])) {
      fail(`authorization response parameter set drifted: ${callbackNames.join(",")}`);
    }
    if (response.headers.get("cache-control") !== "no-store" || response.headers.get("pragma") !== "no-cache") {
      fail("authorization response was cacheable");
    }

    this.pendingCallback = callback.searchParams;
  }

  takeCallback() {
    const callback = this.pendingCallback;
    this.pendingCallback = undefined;
    if (!callback) fail("SDK did not produce an authorization callback");
    return callback;
  }
}

function buildClient(config) {
  return new Client(
    {name: `hitch-${config.scenario}`, version: "1.0.0"},
    {versionNegotiation: {mode: {pin: PROTOCOL_VERSION}}}
  );
}

function buildTransport(config, provider, observations, onInsufficientScope) {
  return new StreamableHTTPClientTransport(new URL(config.endpoint), {
    authProvider: provider,
    fetch: observations.fetch.bind(observations),
    onInsufficientScope,
    maxStepUpRetries: 1
  });
}

async function finishRedirectedAuthorization(transport, provider) {
  await transport.finishAuth(provider.takeCallback());
}

async function connectWithAuthorization(config, provider, observations, onInsufficientScope) {
  const firstClient = buildClient(config);
  const firstTransport = buildTransport(config, provider, observations, onInsufficientScope);

  try {
    await firstClient.connect(firstTransport);
    return {client: firstClient, transport: firstTransport};
  } catch (error) {
    if (!UnauthorizedError.isInstance(error)) throw error;
    await finishRedirectedAuthorization(firstTransport, provider);
    await firstClient.close().catch(() => {});
  }

  const client = buildClient(config);
  const transport = buildTransport(config, provider, observations, onInsufficientScope);
  await client.connect(transport);
  return {client, transport};
}

function textFrom(result) {
  if (result.isError) fail("tool returned isError");
  const text = result.content.find((entry) => entry.type === "text")?.text;
  if (typeof text !== "string") fail("tool result omitted text content");
  return text;
}

async function main() {
  const inputPath = process.argv[2];
  if (!inputPath || process.argv.length !== 3) fail("usage: smoke.mjs CREDENTIAL_JSON");

  const config = loadConfig(inputPath);
  const sdkVersion = installedSdkVersion();
  if (sdkVersion !== "2.0.0") fail(`installed SDK version drifted: ${sdkVersion}`);
  const provider = new HitchOAuthProvider(config);
  const observations = new WireObservations(config);
  let {client, transport} = await connectWithAuthorization(config, provider, observations, "throw");

  const resourceMetadata = expectedResourceMetadataUrl(config.endpoint);
  if (observations.unauthorizedChallenges.length !== 1) {
    fail(`initial authorization used ${observations.unauthorizedChallenges.length} challenges`);
  }
  assertBearerChallenge(observations.unauthorizedChallenges[0], {
    scope: "mcp",
    resourceMetadata,
    error: undefined
  });

  if (client.getProtocolEra() !== "modern") fail("SDK did not negotiate the modern era");
  if (client.getNegotiatedProtocolVersion() !== PROTOCOL_VERSION) fail("protocol version drifted");
  const discover = client.getDiscoverResult();
  if (!discover?.supportedVersions?.includes(PROTOCOL_VERSION)) fail("server/discover result missing pinned version");

  const initial = await client.listTools(undefined, {cacheMode: "refresh"});
  const initialNames = initial.tools.map((tool) => tool.name).sort();
  if (JSON.stringify(initialNames) !== JSON.stringify(["package.echo"])) {
    fail(`initial listing leaked scope-hidden tools: ${initialNames.join(",")}`);
  }
  const baseResult = await client.callTool({
    name: "package.echo",
    arguments: {message: config.scenario}
  });
  if (textFrom(baseResult) !== `echo:${config.scenario}`) fail("base tool result drifted");

  let challenge;
  try {
    await client.callTool({name: "admin.echo", arguments: {message: config.scenario}});
    fail("admin call succeeded before step-up");
  } catch (error) {
    if (!InsufficientScopeError.isInstance(error)) throw error;
    challenge = error;
  }
  if (challenge.requiredScope?.split(/\s+/).sort().join(" ") !== "admin mcp") {
    fail(`scope challenge drifted: ${challenge.requiredScope}`);
  }
  if (challenge.resourceMetadataUrl?.href !== resourceMetadata) {
    fail("typed insufficient-scope resource metadata drifted");
  }
  await client.close();

  ({client, transport} = await connectWithAuthorization(config, provider, observations, "reauthorize"));
  let adminResult;
  try {
    adminResult = await client.callTool({name: "admin.echo", arguments: {message: config.scenario}});
  } catch (error) {
    if (!UnauthorizedError.isInstance(error)) throw error;
    await finishRedirectedAuthorization(transport, provider);
    adminResult = await client.callTool({name: "admin.echo", arguments: {message: config.scenario}});
  }
  if (textFrom(adminResult) !== `admin:${config.scenario}`) fail("admin tool result drifted");

  const steppedUp = await client.listTools(undefined, {cacheMode: "refresh"});
  const steppedUpNames = steppedUp.tools.map((tool) => tool.name).sort();
  if (JSON.stringify(steppedUpNames) !== JSON.stringify(["admin.echo", "package.echo"])) {
    fail(`stepped-up listing drifted: ${steppedUpNames.join(",")}`);
  }

  const grantedScopes = provider.savedTokens?.scope?.split(/\s+/).sort() ?? [];
  if (JSON.stringify(grantedScopes) !== JSON.stringify(["admin", "mcp"])) {
    fail(`stepped-up token scope drifted: ${grantedScopes.join(" ")}`);
  }
  if (provider.authorizationScopes.length !== 2 || provider.authorizationScopes[0] !== "mcp" ||
      provider.authorizationScopes[1] !== "admin mcp") {
    fail(`authorization sequence drifted: ${provider.authorizationScopes.join(" -> ")}`);
  }
  if (observations.insufficientScopeChallenges.length !== 2) {
    fail(`step-up used ${observations.insufficientScopeChallenges.length} insufficient-scope challenges`);
  }
  for (const wireChallenge of observations.insufficientScopeChallenges) {
    assertBearerChallenge(wireChallenge, {
      scope: "admin mcp",
      resourceMetadata,
      error: "insufficient_scope"
    });
  }

  await client.close();
  process.stdout.write(`HITCH_CLIENT_RESULT=${JSON.stringify({
    scenario: config.scenario,
    sdk: "typescript",
    sdk_version: sdkVersion,
    oauth_client: config.auth_method === "none" ? "public" : "confidential",
    token_endpoint_auth_method: config.auth_method,
    protocol_version: PROTOCOL_VERSION,
    protocol_era: "modern",
    discover: "ok",
    initial_listing: initialNames,
    base_call: "ok",
    initial_challenge_scope: "mcp",
    typed_insufficient_scope: "mcp admin",
    insufficient_scope_challenges: observations.insufficientScopeChallenges.length,
    step_up_authorizations: provider.authorizationScopes,
    stepped_up_listing: steppedUpNames,
    stepped_up_call: "ok",
    credential_input: "private_mode_0600_file",
    contains_credentials: false
  })}\n`);
}

await main();
