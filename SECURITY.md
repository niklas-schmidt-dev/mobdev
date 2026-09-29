# Security

Report vulnerabilities privately to the project maintainer through the repository host's private security advisory mechanism once this repository is published. No public reporting address is configured yet. Do not include real API tokens, private app screenshots or device logs in public issues.

The daemon controls developer-authorized devices and installs apps by explicit request. Treat its bearer token as a credential. It binds only to loopback and checks Host/Origin headers. Remote access should use authenticated tunnels rather than public port exposure.

Model keys are currently stored in the local settings file with restrictive permissions where supported, not an OS keychain. Run evidence includes typed values and may contain private device content. A configured hosted model receives UI text and action history only when an agent/draft operation is explicitly started.

No telemetry, public upload, license check or automatic update service is included. Appium connections can be remote and are subject to the security of that server and its drivers.
