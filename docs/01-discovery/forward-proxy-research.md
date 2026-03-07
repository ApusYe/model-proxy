# Forward Proxy + MITM Research

> Date: 2026-03-07
> Status: Research complete, pending decision
> Context: Evaluate feasibility of adding forward proxy mode (HTTPS_PROXY) as a V2 feature

## Motivation

Current ModelProxy uses reverse proxy mode: clients set `ANTHROPIC_BASE_URL=http://localhost:9090` to route traffic. This requires clients to support custom base URL configuration. Some clients (notably GitHub Copilot) do not support custom base URLs but do respect `HTTPS_PROXY` env vars.

Question: Can ModelProxy work as an HTTPS forward proxy, intercepting LLM traffic from any app that sets `HTTPS_PROXY`?

## Key Concepts

### Reverse Proxy (Current V1)

Proxy represents the server. Client thinks it's talking directly to the API server.

```
Client --"you are the API server"--> ModelProxy --> Real API
```

Client configures `BASE_URL=http://localhost:9090`. No TLS between client and proxy.

### Forward Proxy (Proposed V2)

Proxy represents the client. Client knows it's using a proxy.

```
Client --"forward this for me"--> ModelProxy --> Real API
```

Client configures `HTTPS_PROXY=http://localhost:9090`. All HTTPS traffic goes through proxy as CONNECT tunnels.

## CONNECT Tunnel Protocol

When a client uses HTTPS_PROXY, HTTPS requests use the CONNECT method:

1. Client sends `CONNECT api.openai.com:443 HTTP/1.1` (plaintext)
2. Proxy opens TCP connection to `api.openai.com:443`
3. Proxy returns `HTTP/1.1 200 Connection Established`
4. Proxy becomes a dumb byte-relay (tunnel mode)
5. TLS handshake happens inside the tunnel (proxy sees only encrypted bytes)
6. All application data (paths, headers, bodies) encrypted end-to-end

### What the proxy can see

| Visible | Encrypted (invisible) |
|---------|----------------------|
| Target hostname + port (CONNECT line) | URL path, query string |
| SNI hostname (TLS ClientHello) | HTTP headers (Auth, Cookies) |
| Connection timing, byte counts | Request/response bodies |

**Conclusion**: Pure CONNECT tunneling cannot support ModelProxy's model routing (requires reading `model` field in JSON body). MITM is required.

## Selective MITM Architecture

Tools like mitmproxy and Charles Proxy implement selective HTTPS interception:

### How it works

1. Client sends `CONNECT api.openai.com:443`
2. Proxy responds `200` but does NOT relay bytes
3. Proxy opens its own TLS connection to the real server, extracts cert details
4. Proxy generates a leaf certificate on-the-fly (signed by its own CA) mimicking the real cert
5. Proxy completes TLS handshake with client using the forged cert
6. Result: two separate TLS sessions (client-proxy, proxy-server); proxy sees plaintext

### Selective interception

- Known LLM API hosts (e.g., `api.openai.com`, `api.anthropic.com`): MITM, decrypt, apply routing rules
- All other hosts: transparent CONNECT tunnel passthrough (no decryption)

### Certificate trust model

- First run: generate unique CA keypair (RSA key + self-signed root cert with `CA:TRUE`, `keyCertSign`)
- User installs CA cert in macOS Keychain, sets to "Always Trust" (one-time, requires admin password)
- Leaf certs generated per-hostname on-the-fly, signed by CA, cached for reuse
- macOS blocks interception of Apple services regardless (OS-level certificate pinning)

Sources:
- [How mitmproxy works](https://docs.mitmproxy.org/stable/concepts/how-mitmproxy-works/)
- [mitmproxy Certificates](https://docs.mitmproxy.org/stable/concepts/certificates/)

## SwiftNIO Feasibility

### CONNECT handling

SwiftNIO core does not have built-in CONNECT support, but Apple's `swift-nio-examples` provides an official reference implementation (`connect-proxy`):

- `ConnectHandler`: state machine (`idle` -> `beganConnecting` -> `awaitingEnd` -> `upgradeComplete`)
- `GlueHandler`: bidirectional raw byte relay after tunnel establishment
- Pipeline transformation: removes HTTP codecs, installs raw relay handlers

Source: [swift-nio-examples ConnectHandler.swift](https://github.com/apple/swift-nio-examples/blob/main/connect-proxy/Sources/ConnectProxy/ConnectHandler.swift)

### TLS / SSL

| Package | Purpose | MITM suitability |
|---------|---------|-----------------|
| `swift-nio-ssl` (BoringSSL) | TLS handlers for NIO pipeline | Primary option. Supports dynamic handler add/remove at runtime. |
| `swift-nio-transport-services` | Network.framework TLS | Less flexible for dynamic cert injection |
| NIOTLS `SNIHandler` | Read SNI from ClientHello | Hook point for selecting per-hostname cert |

**Certificate generation**: `swift-nio-ssl` explicitly does NOT provide cert generation ("outside scope of this project"). Options:
- BoringSSL C API calls directly
- Swift Security framework
- Shell out to `openssl` CLI

Source: [swift-nio-ssl GitHub](https://github.com/apple/swift-nio-ssl)

### SNI-only routing (alternative, insufficient)

SNI provides only the hostname; cannot see path, headers, or body. Insufficient for model-level routing. Also threatened by Encrypted Client Hello (ECH) in future TLS versions.

## LLM Client Proxy Support

### HTTPS_PROXY env var support

| Client | HTTPS_PROXY | Custom Base URL | More reliable approach |
|--------|:-----------:|:---------------:|----------------------|
| Claude Code CLI | Yes | Yes (`ANTHROPIC_BASE_URL`) | Base URL |
| Anthropic Python SDK | Broken (known bug) | Yes (`base_url` / env var) | Base URL |
| Anthropic Node SDK | Likely broken | Yes (`baseURL`) | Base URL |
| OpenAI Python SDK | Yes (httpx auto) | Yes (`base_url` / env var) | Either works |
| OpenAI Node SDK | No (manual only) | Yes (`baseURL` / env var) | Base URL |
| Cursor IDE | Partial (HTTP/2 issues) | Yes (settings UI) | Base URL |
| Continue.dev | Buggy | Yes (`apiBase`) | apiBase |
| GitHub Copilot | Yes | No (closed system) | HTTPS_PROXY only |

### Key finding

Custom base URL is the more universal and reliable interception mechanism. Every client except GitHub Copilot supports it. `HTTPS_PROXY` support is inconsistent across SDKs.

**Forward proxy's unique value = GitHub Copilot and other closed clients that only support HTTPS_PROXY.**

Sources:
- [Claude Code Enterprise network config](https://code.claude.com/docs/en/network-config)
- [Anthropic SDK proxy bug #923](https://github.com/anthropics/anthropic-sdk-python/issues/923)
- [OpenAI Python SDK proxy docs](https://deepwiki.com/openai/openai-python/7.4-custom-http-clients-and-proxies)
- [GitHub Copilot network settings](https://docs.github.com/en/copilot/concepts/network-settings)
- [Cursor network configuration](https://cursor.com/docs/enterprise/network-configuration)

## Current Architecture Incompatibilities

The current NIO pipeline (`HTTPServerPipeline -> ProxyChannelHandler`) has 5 fundamental incompatibilities with CONNECT:

1. **RequestRouter expects JSON body** - CONNECT has no body; would throw `missingModelField`
2. **URL construction** - builds `baseURL + path`; CONNECT uses `host:port` format
3. **AsyncHTTPClient** - standard HTTP client, cannot negotiate CONNECT tunnels or relay raw TCP
4. **ResponseRelay assumes HTTP framing** - CONNECT switches to raw bytes post-200
5. **No pipeline handler replacement** - CONNECT requires swapping HTTP handlers for raw relay

**Conclusion**: CONNECT requires a separate code path, not modifications to existing forwarding logic.

## Proposed Architecture (V2)

```
Client --CONNECT host:443--> ModelProxy
                                |
                          hostname in LLM registry?
                           /              \
                         Yes               No
                          |                 |
                    MITM decrypt      Transparent tunnel
                    Parse HTTP          (GlueHandler)
                    Route by model
                    Forward to target
```

### New components required

| Component | Responsibility |
|-----------|---------------|
| `ConnectHandler` | Detect CONNECT, parse host:port, decide MITM vs tunnel |
| `GlueHandler` | Bidirectional byte relay for non-LLM traffic |
| `MITMHandler` | TLS termination + HTTP parsing + routing + re-encryption |
| `CertificateAuthority` | CA keypair generation/loading, per-hostname leaf cert signing |
| `CertificateCache` | Cache generated leaf certs (avoid regeneration) |
| `LLMHostRegistry` | Known LLM API hostnames list |

### Dependencies

- `swift-nio-ssl` (already indirect dependency via AsyncHTTPClient)
- BoringSSL C API or equivalent for certificate generation

## Value vs Cost

| Dimension | Reverse Proxy (V1) | Forward Proxy + MITM (V2) |
|-----------|--------------------|-----------------------------|
| Client coverage | Clients with custom base URL | All HTTPS_PROXY-respecting clients |
| Unique incremental value | - | GitHub Copilot + closed clients |
| New code | - | ~6 components, est. 1000-1500 lines |
| New dependencies | - | BoringSSL C API (cert generation) |
| User setup cost | Change 1 env var | Install CA to Keychain + set HTTPS_PROXY |
| Security risk | None | CA private key management |
| Runtime overhead | None | Non-LLM traffic also proxied (latency) |
| Maintenance | Low | High (TLS updates, cert format changes) |
| ECH future risk | No impact | May need adjustment |

## Recommendation

Forward proxy + selective MITM is technically feasible. SwiftNIO ecosystem provides all building blocks. However, ROI depends on how many target users need GitHub Copilot or similar closed-client routing.

**Suggested approach**: Optional "Forward Proxy Mode" in V2, coexisting with current reverse proxy. Implementation order:
1. Transparent CONNECT tunnel (passthrough for all traffic)
2. Selective MITM for known LLM hosts
3. CA management UI in Settings

This feature should not block V1 completion.
