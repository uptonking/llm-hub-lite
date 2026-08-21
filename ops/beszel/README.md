# Beszel monitoring

The hub is proxied by the application Caddy instance at `BESZEL_APP_URL` and
stores all state outside application releases. The agent uses an outbound,
mutually authenticated WebSocket connection, host networking for accurate host
network statistics, and a read-only Docker socket. It deliberately does not
publish port 45876 and does not expose host systemd/D-Bus by default.

The VPS bootstrap starts the hub, creates a native password-authenticated first
account, obtains a persistent universal token, writes the hub public key and
token to root-only files, and then starts the agent. The generated initial login
file is `/etc/llm-hub-lite/beszel-initial-credentials`; remove it after saving
the credentials in a password manager. If a hub database already exists,
bootstrap never guesses or replaces its credentials: use the UI to create a
system or universal token and place them in the configured secret files.

`platformctl start beszel` starts only the hub until both secret files exist,
which makes first boot and recovery safe. Once both files are present it starts
the hub and agent and waits for their native health checks.
