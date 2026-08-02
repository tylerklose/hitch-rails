from __future__ import annotations

import asyncio
import importlib.metadata
import json
import os
import re
import stat
import sys
from html.parser import HTMLParser
from typing import Any
from urllib.parse import parse_qsl, urljoin, urlparse

import httpx2
from mcp.client import Client
from mcp.client.auth import AuthorizationCodeResult, OAuthClientProvider, TokenStorage
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.auth import OAuthClientInformationFull, OAuthClientMetadata, OAuthToken


PROTOCOL_VERSION = "2026-07-28"
SDK_VERSION = "2.0.0"
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36"
)
AUTHORIZATION_PARAMETER_NAMES = {
    "client_id",
    "code_challenge",
    "code_challenge_method",
    "redirect_uri",
    "resource",
    "response_type",
    "scope",
    "state",
}


def fail(message: str) -> None:
    raise RuntimeError(f"Hitch Python client smoke: {message}")


def load_config(path: str) -> dict[str, Any]:
    file_stat = os.lstat(path)
    if not stat.S_ISREG(file_stat.st_mode) or os.path.islink(path):
        fail("credential input must be a regular non-symlink file")
    mode = stat.S_IMODE(file_stat.st_mode)
    if mode != 0o600:
        fail("credential input must be mode 0600")

    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
    for key in ("scenario", "endpoint", "issuer", "redirect_uri", "client_id", "auth_method"):
        if not isinstance(config.get(key), str) or not config[key]:
            fail(f"missing {key}")
    if config["auth_method"] == "client_secret_basic" and (
        not isinstance(config.get("client_secret"), str) or not config["client_secret"]
    ):
        fail("confidential client secret is missing")
    if config["auth_method"] == "none" and config.get("client_secret") is not None:
        fail("public client unexpectedly received a secret")
    if config["auth_method"] not in {"none", "client_secret_basic"}:
        fail("unsupported token endpoint authentication method")

    endpoint = urlparse(config["endpoint"])
    issuer = urlparse(config["issuer"])
    redirect = urlparse(config["redirect_uri"])
    if (
        endpoint.scheme != "http"
        or endpoint.hostname != "127.0.0.1"
        or endpoint.path != "/mcp"
        or endpoint.params
        or endpoint.query
        or endpoint.fragment
        or endpoint.username
        or endpoint.password
    ):
        fail("M5.4 endpoint must be the exact loopback HTTP /mcp resource")
    if (
        (issuer.scheme, issuer.netloc) != (endpoint.scheme, endpoint.netloc)
        or issuer.path not in ("", "/")
        or issuer.params
        or issuer.query
        or issuer.fragment
        or issuer.username
        or issuer.password
    ):
        fail("issuer must be the endpoint origin")
    if (
        redirect.scheme != "http"
        or redirect.hostname not in {"127.0.0.1", "localhost", "::1"}
        or not redirect.path.startswith("/callback/")
        or redirect.params
        or redirect.query
        or redirect.fragment
        or redirect.username
        or redirect.password
    ):
        fail("redirect URI must be a clean loopback HTTP callback")
    return config


def unique_parameters(query: str, label: str) -> dict[str, str]:
    pairs = parse_qsl(query, keep_blank_values=True)
    if len({name for name, _value in pairs}) != len(pairs):
        fail(f"{label} repeated an OAuth parameter")
    return dict(pairs)


def expected_resource_metadata_url(endpoint: str) -> str:
    resource = urlparse(endpoint)
    return f"{resource.scheme}://{resource.netloc}/.well-known/oauth-protected-resource{resource.path}"


def challenge_field(challenge: str | None, name: str) -> str | None:
    if challenge is None:
        return None
    match = re.search(rf'(?:^|[,\s]){re.escape(name)}="([^"]*)"', challenge)
    return match.group(1) if match else None


def assert_bearer_challenge(
    challenge: str | None, *, scope: str, resource_metadata: str, error: str | None
) -> None:
    if challenge is None or re.match(r"^Bearer(?:\s|$)", challenge, re.IGNORECASE) is None:
        fail("MCP response omitted its Bearer challenge")
    actual_scope = " ".join(sorted((challenge_field(challenge, "scope") or "").split()))
    if actual_scope != scope:
        fail("MCP challenge scope drifted")
    if challenge_field(challenge, "resource_metadata") != resource_metadata:
        fail("MCP challenge resource_metadata drifted")
    if challenge_field(challenge, "error") != error:
        fail("MCP challenge error drifted")


class ConsentFormParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.form_count = 0
        self.in_form = False
        self.form_action: str | None = None
        self.form_method = "get"
        self.fields: dict[str, str] = {}
        self.in_code = False
        self.code_buffer: list[str] = []
        self.code_values: list[str] = []

    @staticmethod
    def attributes(values: list[tuple[str, str | None]]) -> dict[str, str]:
        attributes: dict[str, str] = {}
        for name, value in values:
            if name in attributes:
                fail(f"consent form repeated the {name} attribute")
            attributes[name] = value or ""
        return attributes

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = self.attributes(attrs)
        if tag == "form":
            self.form_count += 1
            self.in_form = True
            self.form_action = attributes.get("action")
            self.form_method = attributes.get("method", "get").lower()
        elif tag == "input" and self.in_form and attributes.get("type", "text").lower() == "hidden":
            name = attributes.get("name")
            if name:
                if name in self.fields:
                    fail(f"consent form repeated the {name} field")
                self.fields[name] = attributes.get("value", "")
        elif tag == "code":
            self.in_code = True
            self.code_buffer = []

    def handle_data(self, data: str) -> None:
        if self.in_code:
            self.code_buffer.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "form":
            self.in_form = False
        elif tag == "code" and self.in_code:
            self.code_values.append("".join(self.code_buffer).strip())
            self.in_code = False
            self.code_buffer = []


class WireObservations:
    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint
        self.unauthorized_challenges: list[str | None] = []
        self.insufficient_scope_challenges: list[str | None] = []

    async def observe_response(self, response: httpx2.Response) -> None:
        if str(response.request.url) != self.endpoint or response.request.method != "POST":
            return
        challenge = response.headers.get("www-authenticate")
        if response.status_code == 401:
            self.unauthorized_challenges.append(challenge)
        elif response.status_code == 403:
            self.insufficient_scope_challenges.append(challenge)


class MemoryStorage(TokenStorage):
    def __init__(self, client_info: OAuthClientInformationFull) -> None:
        self._tokens: OAuthToken | None = None
        self._client_info = client_info

    async def get_tokens(self) -> OAuthToken | None:
        return self._tokens

    async def set_tokens(self, tokens: OAuthToken) -> None:
        self._tokens = tokens

    async def get_client_info(self) -> OAuthClientInformationFull | None:
        return self._client_info

    async def set_client_info(self, client_info: OAuthClientInformationFull) -> None:
        self._client_info = client_info


class BrowserAutomation:
    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.callback: AuthorizationCodeResult | None = None
        self.authorization_scopes: list[str] = []

    async def redirect(self, authorization_url: str) -> None:
        parsed = urlparse(authorization_url)
        expected_authorization_endpoint = f"{self.config['issuer'].rstrip('/')}/oauth/authorize"
        endpoint = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
        if endpoint != expected_authorization_endpoint or parsed.params or parsed.fragment:
            fail("SDK redirected to an unexpected authorization endpoint")
        parameters = unique_parameters(parsed.query, "authorization request")
        if set(parameters) != AUTHORIZATION_PARAMETER_NAMES:
            fail(f"authorization parameter set drifted: {','.join(sorted(parameters))}")
        if (
            parameters.get("response_type") != "code"
            or parameters.get("client_id") != self.config["client_id"]
            or parameters.get("redirect_uri") != self.config["redirect_uri"]
            or parameters.get("resource") != self.config["endpoint"]
            or parameters.get("code_challenge_method") != "S256"
            or re.fullmatch(r"[A-Za-z0-9_-]{43}", parameters.get("code_challenge", "")) is None
            or re.fullmatch(r"[A-Za-z0-9_-]{43}", parameters.get("state", "")) is None
        ):
            fail("authorization request security parameters drifted")
        scope = parameters.get("scope")
        if not scope:
            fail("authorization request omitted scope")
        normalized_scope = " ".join(sorted(scope.split()))
        expected_scope = "mcp" if not self.authorization_scopes else "admin mcp"
        if normalized_scope != expected_scope:
            fail(f"authorization scope drifted: {normalized_scope}")
        self.authorization_scopes.append(normalized_scope)

        async with httpx2.AsyncClient(
            follow_redirects=False,
            timeout=20.0,
            headers={"user-agent": BROWSER_USER_AGENT},
        ) as browser:
            consent = await browser.get(authorization_url)
            if consent.status_code != 200:
                fail(f"consent screen returned {consent.status_code}")
            form = ConsentFormParser()
            form.feed(consent.text)
            form.close()
            if form.form_count != 1:
                fail(f"consent screen rendered {form.form_count} forms")
            if form.form_method != "post" or not form.form_action:
                fail("consent screen omitted its POST form action")
            action = urljoin(authorization_url, form.form_action)
            action_url = urlparse(action)
            if (
                (action_url.scheme, action_url.netloc, action_url.path)
                != (parsed.scheme, parsed.netloc, parsed.path)
                or action_url.params
                or action_url.query
                or action_url.fragment
            ):
                fail("consent form action drifted")
            if not form.fields.get("authenticity_token"):
                fail("consent screen omitted the CSRF token")
            for name in AUTHORIZATION_PARAMETER_NAMES:
                if form.fields.get(name) != parameters[name]:
                    fail(f"consent form changed the {name} parameter")
            for granted_scope in scope.split():
                if granted_scope not in form.code_values:
                    fail(f"consent screen did not display the {granted_scope} scope")
            if parameters["resource"] not in form.code_values:
                fail("consent screen did not display the target resource")
            response = await browser.post(action, data=form.fields)
        if response.status_code not in (302, 303):
            fail(f"authorization endpoint returned {response.status_code}")
        if response.headers.get("cache-control") != "no-store" or response.headers.get("pragma") != "no-cache":
            fail("authorization response was cacheable")

        location = response.headers.get("location")
        if not location:
            fail("authorization response omitted Location")
        callback = urlparse(location)
        expected = urlparse(self.config["redirect_uri"])
        if (callback.scheme, callback.netloc, callback.path) != (expected.scheme, expected.netloc, expected.path):
            fail("authorization response targeted an unregistered redirect")
        values = unique_parameters(callback.query, "authorization response")
        if set(values) != {"code", "iss", "state"}:
            fail(f"authorization response parameter set drifted: {','.join(sorted(values))}")
        if not values.get("code"):
            fail("authorization response omitted code")
        if values.get("state") != parameters["state"]:
            fail("authorization response state mismatch")
        if values.get("iss") != self.config["issuer"]:
            fail("authorization response issuer mismatch")
        self.callback = AuthorizationCodeResult(
            code=values["code"],
            state=values.get("state"),
            iss=values.get("iss"),
        )

    async def callback_result(self) -> AuthorizationCodeResult:
        result = self.callback
        self.callback = None
        if result is None:
            fail("SDK did not produce an authorization callback")
        return result


def text_from(result: Any) -> str:
    if result.is_error:
        fail("tool returned isError")
    for entry in result.content:
        if getattr(entry, "type", None) == "text" and isinstance(getattr(entry, "text", None), str):
            return entry.text
    fail("tool result omitted text content")


async def run(path: str) -> dict[str, Any]:
    config = load_config(path)
    sdk_version = importlib.metadata.version("mcp")
    if sdk_version != SDK_VERSION:
        fail(f"installed SDK version drifted: {sdk_version}")
    client_info = OAuthClientInformationFull(
        client_id=config["client_id"],
        client_secret=config.get("client_secret"),
        redirect_uris=[config["redirect_uri"]],
        token_endpoint_auth_method=config["auth_method"],
        grant_types=["authorization_code"],
        response_types=["code"],
        scope="mcp admin",
        issuer=config["issuer"],
    )
    storage = MemoryStorage(client_info)
    browser = BrowserAutomation(config)
    metadata = OAuthClientMetadata(
        redirect_uris=[config["redirect_uri"]],
        token_endpoint_auth_method=config["auth_method"],
        grant_types=["authorization_code"],
        response_types=["code"],
        client_name=f"Hitch {config['scenario']}",
    )
    provider = OAuthClientProvider(
        config["endpoint"],
        metadata,
        storage,
        redirect_handler=browser.redirect,
        callback_handler=browser.callback_result,
    )
    observations = WireObservations(config["endpoint"])
    resource_metadata = expected_resource_metadata_url(config["endpoint"])

    async with httpx2.AsyncClient(
        auth=provider,
        timeout=20.0,
        event_hooks={"response": [observations.observe_response]},
    ) as http_client:
        transport = streamable_http_client(
            config["endpoint"],
            http_client=http_client,
            terminate_on_close=False,
        )
        async with Client(transport, mode="auto", cache=None) as client:
            if client.protocol_version != PROTOCOL_VERSION:
                fail(f"protocol version drifted: {client.protocol_version}")
            discover = client.session.discover_result
            if discover is None or PROTOCOL_VERSION not in discover.supported_versions:
                fail("server/discover result missing the negotiated modern version")
            if len(observations.unauthorized_challenges) != 1:
                fail(f"initial authorization used {len(observations.unauthorized_challenges)} challenges")
            assert_bearer_challenge(
                observations.unauthorized_challenges[0],
                scope="mcp",
                resource_metadata=resource_metadata,
                error=None,
            )

            initial = await client.list_tools(cache_mode="refresh")
            initial_names = sorted(tool.name for tool in initial.tools)
            if initial_names != ["package.echo"]:
                fail(f"initial listing leaked scope-hidden tools: {initial_names}")

            base_result = await client.call_tool("package.echo", {"message": config["scenario"]})
            if text_from(base_result) != f"echo:{config['scenario']}":
                fail("base tool result drifted")

            admin_result = await client.call_tool("admin.echo", {"message": config["scenario"]})
            if text_from(admin_result) != f"admin:{config['scenario']}":
                fail("admin tool result drifted")

            stepped_up = await client.list_tools(cache_mode="refresh")
            stepped_up_names = sorted(tool.name for tool in stepped_up.tools)
            if stepped_up_names != ["admin.echo", "package.echo"]:
                fail(f"stepped-up listing drifted: {stepped_up_names}")

    scopes = sorted(((storage._tokens.scope if storage._tokens else None) or "").split())
    if scopes != ["admin", "mcp"]:
        fail(f"stepped-up token scope drifted: {scopes}")
    if browser.authorization_scopes != ["mcp", "admin mcp"]:
        fail(f"authorization sequence drifted: {browser.authorization_scopes}")
    if len(observations.insufficient_scope_challenges) != 1:
        fail(f"step-up used {len(observations.insufficient_scope_challenges)} insufficient-scope challenges")
    assert_bearer_challenge(
        observations.insufficient_scope_challenges[0],
        scope="admin mcp",
        resource_metadata=resource_metadata,
        error="insufficient_scope",
    )

    return {
        "scenario": config["scenario"],
        "sdk": "python",
        "sdk_version": sdk_version,
        "oauth_client": "public" if config["auth_method"] == "none" else "confidential",
        "token_endpoint_auth_method": config["auth_method"],
        "protocol_version": PROTOCOL_VERSION,
        "protocol_era": "modern",
        "discover": "ok",
        "initial_listing": initial_names,
        "base_call": "ok",
        "initial_challenge_scope": "mcp",
        "step_up_scope": "mcp admin",
        "insufficient_scope_challenges": len(observations.insufficient_scope_challenges),
        "step_up_authorizations": browser.authorization_scopes,
        "stepped_up_listing": stepped_up_names,
        "stepped_up_call": "ok",
        "credential_input": "private_mode_0600_file",
        "contains_credentials": False,
    }


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: smoke.py CREDENTIAL_JSON")
    result = asyncio.run(run(sys.argv[1]))
    print(f"HITCH_CLIENT_RESULT={json.dumps(result, sort_keys=True, separators=(',', ':'))}")


if __name__ == "__main__":
    main()
