<h1 align="center">GF-Patterns Collection</h1>

> Curated, validated, and categorized regex patterns for [`gf`](https://github.com/tomnomnom/gf) — 125 pattern files across 31 vulnerability/recon categories.

## Quick Start

```bash
# Move patterns into gf's pattern directory
mkdir -p ~/.gf
cp ./gf-patterns/*.json ~/.gf/

# Verify install
gf -list

# Use directly (redirect output to a file per pattern)
gf xss urls.txt > gf-xss.txt
gf sqli urls.txt > gf-sqli.txt
gf rce-params urls.txt > gf-rce-params.txt
gf secrets urls.txt > gf-secrets.txt
```

## Categories Overview

| Category | Files | Key Files | Description |
|---|---|---|---|
| **secrets** | 37 | `api-keys.json`, `aws-keys_secrets.json`, `aws-s3_secrets.json`, `aws-mws-key.json`, `aws-secret-key.json`, `asymmetric-keys_secrets.json`, `discord-webhooks.json`, `facebook-oauth_secrets.json`, `facebook-token_secrets.json`, `firebase.json`, `firebase_secrets.json`, `github.json`, `github_secrets.json`, `google-keys_secrets.json`, `google-oauth_secrets.json`, `google-service-account_secrets.json`, `google-token_secrets.json`, `heroku-keys_secrets.json`, `jwt.json`, `mailchimp-keys_secrets.json`, `mailgun-keys_secrets.json`, `npm-tokens.json`, `paypal-token_secrets.json`, `picatic-keys_secrets.json`, `pypi-tokens.json`, `secrets-generic.json`, `secrets.json`, `slack-token.json`, `slack-token_secrets.json`, `slack-webhook.json`, `slack-webhook_secrets.json`, `square-keys_secrets.json`, `stripe-keys_secrets.json`, `twilio-keys_secrets.json`, `twitter-oauth_secrets.json`, `twitter-secret.json`, `twitter-token_secrets.json` | API keys, tokens, credentials, cloud secrets |
| **rce** | 9 | `rce-params.json`, `rce-output.json`, `php-code-execution.json`, `php-command-execution.json`, `php-sinks.json`, `exec-functions.json`, `deserialization-sinks.json`, `truffle.json`, `cmdi.json` | Remote Code Execution (params + output evidence) |
| **sqli** | 3 | `sqli.json`, `sqli-error.json`, `nosqli.json` | SQLi + NoSQLi (params + error messages) |
| **xss** | 2 | `xss.json`, `domxss.json` | Cross-Site Scripting (reflected + DOM) |
| **lfi** | 5 | `lfi.json`, `image-path-traversal.json`, `php-read-filesystem.json`, `php-write-filesystem.json`, `php-open-filesystem-handler.json` | Local File Inclusion / Path Traversal |
| **rfi** | 1 | `rfi.json` | Remote File Inclusion |
| **ssrf** | 1 | `ssrf.json` | Server-Side Request Forgery |
| **redirect** | 1 | `redirect.json` | Open Redirect |
| **idor** | 1 | `idor.json` | Insecure Direct Object Reference |
| **ssti** | 1 | `ssti.json` | Server-Side Template Injection |
| **csti** | 1 | `csti.json` | Client-Side Template Injection |
| **crlf** | 1 | `crlf.json` | CRLF Injection / Header Smuggling |
| **xxe** | 4 | `xxe.json`, `xxe-params.json`, `xml-parsing.json`, `xpath.json` | XML External Entity |
| **php** | 12 | `php-callback-functions.json`, `php-code-execution.json`, `php-command-execution.json`, `php-curl.json`, `php-errors.json`, `php-informationdisclosure.json`, `php-open-filesystem-handler.json`, `php-read-filesystem.json`, `php-serialized.json`, `php-sinks.json`, `php-sources.json`, `php-write-filesystem.json` | PHP-specific sinks, sources, errors |
| **url-analysis** | 6 | `api-endpoints.json`, `endpoints.json`, `url-extraction.json`, `url-has-params.json`, `url-parameters.json`, `interestingparams.json` | URL extraction, parameters, endpoints |
| **recon** | 11 | `interesting-extensions.json`, `interesting-subdomains.json`, `frameworks-tech.json`, `modern-frameworks.json`, `cloud-resources.json`, `servers.json`, `takeovers.json`, `sensitive-files.json`, `debug-pages.json`, `debug_logic.json`, `source-leak.json` | Subdomains, extensions, frameworks, tech |
| **cip** | 6 | `ip.json`, `http-headers-raw.json`, `http-auth.json`, `crypto.json`, `authz-keywords.json`, `cors.json` | Information disclosure (IP, headers, auth) |
| **javascript** | 4 | `js-sinks.json`, `js-variables.json`, `js-interesting.json`, `json-secrets.json` | JS sinks, variables, secrets |
| **go** | 1 | `go-func-defs.json` | Go function definitions |
| **c** | 1 | `c-unsafe-functions.json` | C unsafe functions |
| **buffer-overflow** | 1 | `bufferoverflow.json` | Buffer overflow indicators |
| **content-analysis** | 6 | `badwords.json`, `swearwords.json`, `quoted-strings.json`, `typos.json`, `base64.json`, `parser-functions.json` | Badwords, quotes, base64, etc. |
| **ai-services** | 4 | `ai-services.json`, `anthropic.json`, `cohere.json`, `groq.json` | AI/ML service endpoints and keys |
| **oauth-config** | 3 | `oauth.json`, `oauth-config.json`, `openapi.json` | OAuth / OpenAPI configs |
| **uploads** | 2 | `upload-fields.json`, `file-upload.json` | File upload fields + endpoints |
| **graphql** | 1 | `graphql.json` | GraphQL introspection, mutations, params |
| **injection** | 1 | `injection.json` | Generic injection-prone params |
| **framework-specific** | 3 | `laravel.json`, `springboot.json`, `aspnet.json` | Laravel, Spring Boot, ASP.NET specifics |
| **saml** | 1 | `saml.json` | SAML / SSO assertions |
| **websocket** | 1 | `websocket.json` | WebSocket endpoints |

## Key Files by Use Case

### Bug Bounty Recon
```bash
# Find endpoints
gf api-endpoints urls.txt > gf-api-endpoints.txt
gf endpoints urls.txt > gf-endpoints.txt
gf interestingparams urls.txt > gf-interestingparams.txt
gf url-extraction urls.txt > gf-url-extraction.txt
gf url-parameters urls.txt > gf-url-parameters.txt

# Find secrets
gf secrets urls.txt > gf-secrets.txt
gf api-keys urls.txt > gf-api-keys.txt
gf aws-keys_secrets urls.txt > gf-aws-keys_secrets.txt
gf github_secrets urls.txt > gf-github_secrets.txt
gf google-keys_secrets urls.txt > gf-google-keys_secrets.txt
gf slack-token_secrets urls.txt > gf-slack-token_secrets.txt

# Find subdomain takeovers
gf takeovers urls.txt > gf-takeovers.txt

# Tech stack fingerprinting
gf frameworks-tech urls.txt > gf-frameworks-tech.txt
gf modern-frameworks urls.txt > gf-modern-frameworks.txt
gf interesting-extensions urls.txt > gf-interesting-extensions.txt
gf interesting-subdomains urls.txt > gf-interesting-subdomains.txt
gf cloud-resources urls.txt > gf-cloud-resources.txt
gf servers urls.txt > gf-servers.txt
gf sensitive-files urls.txt > gf-sensitive-files.txt
gf debug-pages urls.txt > gf-debug-pages.txt
gf debug_logic urls.txt > gf-debug_logic.txt
gf source-leak urls.txt > gf-source-leak.txt      # .git/.env/.svn/backup leaks (73 patterns)
```

### Vulnerability Hunting
```bash
# RCE
gf rce-params urls.txt > gf-rce-params.txt      # Suspicious parameter names (48 patterns)
gf rce-output responses.txt > gf-rce-output.txt # Shell evidence in responses
gf cmdi urls.txt > gf-cmdi.txt            # Command injection params (20 patterns)

# SQLi / NoSQLi
gf sqli urls.txt > gf-sqli.txt            # SQLi parameter names (29 patterns)
gf sqli-error responses.txt > gf-sqli-error.txt # Database error messages
gf nosqli urls.txt > gf-nosqli.txt          # NoSQL injection params (47 patterns)

# GraphQL
gf graphql urls.txt > gf-graphql.txt         # GraphQL endpoints, mutations, params (20 patterns)

# XSS
gf xss urls.txt > gf-xss.txt             # Reflected XSS params (38 patterns)
gf domxss urls.txt > gf-domxss.txt          # DOM XSS sinks (8 patterns)

# SSRF
gf ssrf urls.txt > gf-ssrf.txt            # SSRF parameter names (115 patterns)

# LFI/RFI
gf lfi urls.txt > gf-lfi.txt             # LFI params (33 patterns)
gf rfi urls.txt > gf-rfi.txt             # RFI params with http:// (18 patterns)
gf image-path-traversal urls.txt > gf-image-path-traversal.txt # Image path traversal

# Redirect
gf redirect urls.txt > gf-redirect.txt        # Open redirect params (122 patterns)

# IDOR
gf idor urls.txt > gf-idor.txt            # Object reference params (13 patterns)

# SSTI / CSTI
gf ssti urls.txt > gf-ssti.txt            # Server-side template params (8 patterns)
gf csti urls.txt > gf-csti.txt            # Client-side template injection (15 patterns)

# CRLF
gf crlf urls.txt > gf-crlf.txt            # CRLF/header smuggling (16 patterns)

# XXE
gf xxe responses.txt > gf-xxe.txt        # XXE payloads/errors
gf xxe-params urls.txt > gf-xxe-params.txt      # XXE DTD/ENTITY param markers (14 patterns)
gf xml-parsing urls.txt > gf-xml-parsing.txt     # XML parsing libraries
gf xpath urls.txt > gf-xpath.txt           # XPath errors
```

### PHP-Specific
```bash
gf php-sinks urls.txt > gf-php-sinks.txt           # Dangerous PHP functions
gf php-code-execution urls.txt > gf-php-code-execution.txt  # Code execution functions
gf php-command-execution urls.txt > gf-php-command-execution.txt # Command execution functions
gf php-callback-functions urls.txt > gf-php-callback-functions.txt # Callback functions
gf php-curl urls.txt > gf-php-curl.txt            # cURL usage
gf php-errors responses.txt > gf-php-errors.txt     # PHP error disclosure
gf php-informationdisclosure urls.txt > gf-php-informationdisclosure.txt # Info disclosure sinks
gf php-serialized responses.txt > gf-php-serialized.txt # Serialized data
gf php-sources urls.txt > gf-php-sources.txt         # User input sources
gf php-open-filesystem-handler urls.txt > gf-php-open-filesystem-handler.txt # Filesystem handlers
gf php-read-filesystem urls.txt > gf-php-read-filesystem.txt # File read operations
gf php-write-filesystem urls.txt > gf-php-write-filesystem.txt # File write operations
```

### JavaScript Analysis
```bash
gf js-sinks urls.txt > gf-js-sinks.txt        # Dangerous JS sinks
gf js-variables urls.txt > gf-js-variables.txt    # Variable assignments
gf js-interesting urls.txt > gf-js-interesting.txt  # Interesting JS patterns
gf json-secrets responses.txt > gf-json-secrets.txt # Secrets in JSON
```

### C/C++ Analysis
```bash
gf c-unsafe-functions urls.txt > gf-c-unsafe-functions.txt # strcpy, gets, etc.
gf bufferoverflow urls.txt > gf-bufferoverflow.txt     # Buffer overflow indicators
```

### Information Disclosure / CIP
```bash
gf ip urls.txt > gf-ip.txt                    # IPv4 addresses
gf http-headers-raw responses.txt > gf-http-headers-raw.txt # Raw HTTP headers
gf http-auth urls.txt > gf-http-auth.txt             # Auth headers
gf authz-keywords urls.txt > gf-authz-keywords.txt        # Authorization keywords
gf crypto urls.txt > gf-crypto.txt                # Crypto patterns
gf cors urls.txt > gf-cors.txt                  # CORS headers
gf servers responses.txt > gf-servers.txt          # Server headers
```

### Go Analysis
```bash
gf go-func-defs urls.txt > gf-go-func-defs.txt # Go function definitions
```

### Content Analysis
```bash
gf badwords urls.txt > gf-badwords.txt
gf swearwords urls.txt > gf-swearwords.txt
gf quoted-strings responses.txt > gf-quoted-strings.txt
gf typos urls.txt > gf-typos.txt
gf base64 responses.txt > gf-base64.txt
gf parser-functions urls.txt > gf-parser-functions.txt
```

### AI Services
```bash
gf ai-services urls.txt > gf-ai-services.txt
gf anthropic urls.txt > gf-anthropic.txt
gf cohere urls.txt > gf-cohere.txt
gf groq urls.txt > gf-groq.txt
```

### OAuth / Config
```bash
gf oauth urls.txt > gf-oauth.txt           # OAuth endpoints, tokens, grant types (70 patterns)
gf oauth-config urls.txt > gf-oauth-config.txt    # client_id/client_secret in configs
gf openapi urls.txt > gf-openapi.txt
```

### SAML / SSO
```bash
gf saml urls.txt > gf-saml.txt            # SAML assertions, endpoints (61 patterns)
```

### WebSockets
```bash
gf websocket urls.txt > gf-websocket.txt       # ws://, wss://, socket.io endpoints (42 patterns)
```

### Framework-Specific
```bash
gf laravel urls.txt > gf-laravel.txt         # Laravel routes, sessions, env (43 patterns)
gf springboot urls.txt > gf-springboot.txt      # Spring Boot actuators, mappings (49 patterns)
gf aspnet urls.txt > gf-aspnet.txt          # ASP.NET endpoints, handlers (47 patterns)
```

### File Uploads
```bash
gf upload-fields urls.txt > gf-upload-fields.txt   # <input type=file> fields
gf file-upload urls.txt > gf-file-upload.txt     # Upload endpoints + params (50 patterns)
```

## Pattern Structure

Each `.json` file contains:

```json
{
  "flags": "-iE",           # grep flags (i=case-insensitive, E=extended regex, etc.)
  "pattern": "regex",       # Single pattern (if "pattern" key)
  "patterns": ["regex1", "regex2"]  # Multiple patterns (if "patterns" key)
}
```

## Flags Reference

| Flag | Meaning |
|---|---|
| `-i` | Case insensitive |
| `-E` | Extended regex |
| `-H` | Show filename |
| `-n` | Show line number |
| `-r` | Recursive |
| `-o` | Only matching part |
| `-a` | Treat binary as text |
| `-P` | Perl-compatible regex |

## File Naming Convention

- `<vuln-class>.json` — Primary pattern file (e.g., `xss.json`, `sqli.json`)
- `<vuln-class>-<variant>.json` — Specialized variants (e.g., `rce-params.json`, `rce-output.json`)
- `<tech>-<purpose>.json` — Technology-specific (e.g., `php-sinks.json`, `js-variables.json`)
- `<category>-<type>.json` — Category grouped (e.g., `secrets-generic.json`, `authz-keywords.json`)

## Validation

All 125 files pass `jq empty` JSON validation. Run:
```bash
cd gf-patterns && for f in *.json; do jq empty "$f" || echo "INVALID: $f"; done
```

## Machine-Readable Index

See category-index.json for programmatic access to categories and file mappings.
