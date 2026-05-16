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
