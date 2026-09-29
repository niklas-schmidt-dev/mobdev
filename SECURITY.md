# Security

Report vulnerabilities privately through the repository host's security advisory feature. Do not include real tokens, device screenshots or logs in public issues.

What to know:

- The Mac app controls a real phone with the user's accounts. Its API binds to 127.0.0.1, requires a bearer token and rejects browser requests (`Origin`) and foreign `Host` headers. The stdio MCP bridge reads the token from a 0600 file.
- Remote access goes through a relay over an outgoing WebSocket. Agents authenticate with a client key derived from a secret that stays on the Mac. Anyone with the client key can control the phone; rotating it in the app revokes it.
- The hosted relay (relay.mobdev.sh) additionally requires an access token from the dashboard, stored as a SHA-256 hash in D1. Requests and screenshots pass through memory only.
- The dashboard uses WorkOS AuthKit sessions (encrypted cookies) and CSRF checks on server functions. Accounts can be deleted from the dashboard.
- No telemetry. Text recognition runs on the Mac.
