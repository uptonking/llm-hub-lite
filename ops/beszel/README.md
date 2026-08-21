# Beszel monitoring

The hub is proxied by the application Caddy instance at `BESZEL_APP_URL` and
stores all state outside application releases. The agent uses an outbound,
mutually authenticated WebSocket connection and host networking for accurate
host network statistics. Docker metrics pass through a loopback-only socket
proxy that permits container read endpoints; the agent does not mount the real
Docker socket. Port 45876 is not public. A read-only system D-Bus mount enables
visibility into Docker, containerd, SSH, and platform systemd units.

The VPS bootstrap starts the hub, creates a native password-authenticated first
account, obtains a persistent universal token, writes the hub public key and
token to root-only files, and then starts the agent. The generated initial login
file is `/etc/llm-hub-lite/beszel-initial-credentials`; remove it after saving
the credentials in a password manager. If a hub database already exists,
bootstrap never guesses or replaces its credentials: use the UI to create a
system or universal token and place them in the configured secret files.

`platformctl start beszel` starts only the hub until both secret files exist,
which makes first boot and recovery safe. Once both files are present it starts
the hub, socket proxy, and agent and waits for their native health checks.

Bootstrap also configures baseline status, CPU, memory, and disk alerts. Set
`BESZEL_HEARTBEAT_URL` in the root-only Beszel environment to an external
dead-man endpoint if complete VPS outage notification is required.
