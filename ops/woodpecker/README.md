# Woodpecker production service

Woodpecker is a separate Compose project whose database and agent identity live
under `/opt/platform/woodpecker`. Image pins come from
`/etc/llm-hub-lite/images.env`; OAuth and agent secrets remain in the root-only
project `.env` file.

Use the host controller for all operations:

```bash
platformctl status
platformctl restart woodpecker
platformctl upgrade woodpecker
platformctl logs woodpecker
```

The agent has root-equivalent Docker socket access and must remain dedicated to
the trusted `uptonking/llm-hub-lite` repository. Pull-request and fork events
must stay disabled. Upgrades are refused while a workflow is running unless the
operator explicitly sets `FORCE_WOODPECKER_UPGRADE=1`.
