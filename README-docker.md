# subconverter-docker

## Edge image from this source tree

This repository includes a small multi-stage Docker build at the repository root. It builds the current checkout and produces a `scratch` runtime image containing only the static `subconverter` binary, `base/`, and CA certificates.

```bash
docker build -t subconverter-edge:latest .
docker run -d --restart=always -p 25500:25500 --name subconverter subconverter-edge:latest
curl http://localhost:25500/version
```

For the smallest image, omit bundled rule files:

```bash
docker build --build-arg INCLUDE_RULES=0 -t subconverter-edge:tiny .
```

For ARM edge devices, build with Docker Buildx, for example:

```bash
docker buildx build --platform linux/arm64 -t subconverter-edge:arm64 --load .
```

## Subscription servers rejecting converter headers

Some subscription servers return HTTP 403 when requests contain
`SubConverter-Request` or `SubConverter-Version`. With a binary built from this
source, disable those two headers in the active preferences file:

```toml
[common]
send_request_headers = false
```

For INI use `send_request_headers=false` in `[common]`; for YAML use
`send_request_headers: false` under `common`. The default is `true`. This setting
affects outgoing HTTP requests, preserves the existing User-Agent handling,
and does not change conversion rules or additional nodes. Restart subconverter
after changing the setting. Existing images must be rebuilt to support it.

## Preserving the subscription's own Clash sections

Many panels now serve a fully customised Clash config. A common pattern is that every node's
`server` is a generated subdomain while the real hostname is published only in the config's own
`hosts:` mapping:

```yaml
hosts:
  9689b1ce-43dc-4623-b35c-b41757bc39bd.panel-cdn.example: e8b6cd12-66ba-43e2-bfb3-10c3584317a1.real-host.example
```

Without that mapping every node ends up with an unresolvable server address.

When a request supplies a template (`&config=<base or rule.ini>`), which is what OpenClash always
does, earlier builds rendered the template and kept only `proxies`, `proxy-groups` and `rules`
from the subscription. Everything else - `hosts`, `dns`, `tun`, `sniffer`, `rule-providers`, ...
- was silently dropped.

The converter now merges the source subscription's top-level sections into the generated config:

* `proxies`, `proxy-groups` and `rules` are never copied, they are regenerated.
* `hosts` is always preserved, even when the template defines it.
* Every other source key that the template does not define is preserved as-is.
* `dns` is deep merged, so the panel's `use-hosts`, `fake-ip-filter` and
  `proxy-server-nameserver` survive next to template DNS entries.
* Deployment-owned keys are not copied, so the template / router UI keeps control of listeners
  and the control plane: `port`, `socks-port`, `mixed-port`, `redir-port`, `tproxy-port`,
  `allow-lan`, `bind-address`, `mode`, `log-level`, `ipv6`, `external-controller`,
  `external-controller-pipe`, `external-controller-cors`, `external-controller-tls`, `secret`,
  `authentication`, `external-ui`, `external-ui-name`, `external-ui-url`, `external-ui-base-dir`,
  `tproxy`. This matters because panels often ship `mixed-port` while the base template opens
  `port` + `socks-port`; copying it verbatim would make the core fight over the same port.

Request arguments:

| argument | default | effect |
| --- | --- | --- |
| `preserve_source=false` | `true` | disable the merge entirely |
| `preserve=<key>[,<key>...]` | `hosts` | extra keys to copy even when the template defines them or they are deployment-owned |
| `preserve_all=true` | `false` | copy every source key over the template, except regenerated and deployment-owned ones |
| `preserve_defined=true` | `false` | let the source win whenever both sides define a key |

Check that a conversion kept the mapping:

```bash
curl -sS -A 'clash.meta' -G \
  --data-urlencode 'target=clash' \
  --data-urlencode 'url=<subscription url>' \
  --data-urlencode 'config=<template url>' \
  http://127.0.0.1:25500/sub | grep -n '^hosts:'
```

The upstream User-Agent decides the format the panel returns: it answers with a base64 node list
for unknown clients and with a Clash config only for clients it recognises. subconverter forwards
the incoming request's `User-Agent`, so send the one the panel expects (OpenClash sends its
`sub_ua`, usually `clash.meta`). If the panel answers with anything other than a Clash config the
source is not recognised as one and there is nothing to preserve.

## Build with GitHub Actions

For infrequent edge deployments, use the manual workflow `.github/workflows/edge-docker.yml`.

1. Push this repository to GitHub.
2. Open `Actions` -> `Build Edge Docker Image` -> `Run workflow`.
3. Set `platforms` to the target device, usually `linux/arm64`.
4. Keep `upload_tar=true` to download a portable Docker image archive.

After the workflow finishes, download the `subconverter-edge-images` artifact and load it on the edge device:

```bash
gunzip subconverter-edge-linux-arm64.tar.gz
docker load -i subconverter-edge-linux-arm64.tar
docker run -d --restart=always -p 25500:25500 --name subconverter subconverter-edge:linux-arm64
```

To push a multi-arch image to GitHub Container Registry instead, set `push_ghcr=true`. The image name is:

```txt
ghcr.io/<owner>/<repo>-edge:<tag>
```

For running this docker, simply use the following commands:
```bash
# run the container detached, forward internal port 25500 to host port 25500
docker run -d --restart=always -p 25500:25500 asdlokj1qpi23/subconverter:latest
# then check its status
curl http://localhost:25500/version
# if you see `subconverter vx.x.x backend` then the container is up and running
```
Or run in docker-compose:
```yaml
---
version: '3'
services:
  subconverter:
    image: asdlokj1qpi23/subconverter:latest
    container_name: subconverter
    ports:
      - "15051:25500"
    restart: always
```

If you want to update `pref` configuration inside the docker, you can use the following command:
```bash
# assume your configuration file name is `newpref.ini`
curl -F "data=@newpref.ini" http://localhost:25500/updateconf?type=form\&token=password
# you may want to change this token in your configuration file
```

For those who want to use their own `pref` configuration and/or rules, snippets, profiles:
```txt
# you can save the files you want to replace to a folder, then copy it into to the docker
# using the latest build of the official docker
FROM tindy2013/subconverter:latest
# assume your files are inside replacements/
# subconverter folder is located in /base/, which has the same structure as the base/ folder in the repository
COPY replacements/ /base/
# expose internal port
EXPOSE 25500
# notice that you still need to use '-p 25500:25500' when starting the docker to forward this port
```
Save the content above to a `Dockerfile`, then run:
```bash
# build with this Dockerfile and tag it subconverter-custom
docker build -t subconverter-custom:latest .
# run the docker detached, forward internal port 25500 to host port 25500
docker run -d --restart=always -p 25500:25500 subconverter-custom:latest
# then check its status
curl http://localhost:25500/version
# if you see `subconverter vx.x.x backend` then the container is up and running
```
