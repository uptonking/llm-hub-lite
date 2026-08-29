# roadmap

# repos

- For a private GitHub repository, also install a root-only GitHub token on every VPS and pass GITHUB_TOKEN_FILE during bootstrap.
# bootstrap
- repeated container creation

```log
[+] Running 1/1
 ✔ Container foundation-caddy-caddy-1  Healthy                                                               6.0s
[+] Running 1/1
 ✔ Container foundation-beszel-worker-beszel-socket-proxy-1  Healthy                                        42.4s
[+] Running 2/2
 ✔ Container foundation-beszel-worker-beszel-socket-proxy-1  Healthy                                        16.0s
 ✔ Container foundation-beszel-worker-beszel-agent-1         Healthy                                        11.8s
Beszel follower credentials provisioned from enrollment bundle
Recreating foundation project to apply installed configuration: caddy
[+] Running 1/1
 ✔ Container foundation-caddy-caddy-1  Healthy                                                               7.5s
Recreating foundation project to apply installed configuration: beszel-worker
[+] Running 2/2
 ✔ Container foundation-beszel-worker-beszel-agent-1         Healthy                                        12.7s
 ✔ Container foundation-beszel-worker-beszel-socket-proxy-1  Healthy
```

# more
