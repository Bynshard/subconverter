#!/bin/sh
# Deploy a subconverter edge image onto the router and prove it is serving.
#
# Run ON THE ROUTER (iStoreOS / OpenWrt) as root:
#   ssh root@192.168.100.1 'sh -s' < scripts/deploy-edge-image.sh
#   IMAGE=ghcr.io/bynshard/subconverter-edge:edge-linux-arm64 \
#     ssh root@192.168.100.1 'sh -s' < scripts/deploy-edge-image.sh
#
# Environment:
#   IMAGE  image reference to deploy (default: the rolling arm64 edge tag)
#   NAME   container name (default: subconverter)
#
# The container is recreated with the exact spec this router uses:
#   --network host, -v /etc/subconverter:/base, -w /base, --restart=always
# The previous image is retagged as subconverter-rollback:<timestamp> first, so a
# rollback is one command:
#   docker rm -f subconverter && docker run -d --name subconverter --restart=always \
#     --network host -v /etc/subconverter:/base -w /base subconverter-rollback:<stamp>
set -e

IMAGE="${IMAGE:-ghcr.io/bynshard/subconverter-edge:edge-linux-arm64}"
NAME="${NAME:-subconverter}"
PORT=25500

echo "== 1/5 pulling $IMAGE"
docker pull "$IMAGE"

CUR_IMAGE="$(docker inspect "$NAME" --format '{{.Config.Image}}' 2>/dev/null || true)"
STAMP="$(date +%Y%m%d%H%M%S)"
if [ -n "$CUR_IMAGE" ]; then
    echo "== 2/5 current image is $CUR_IMAGE, tagging rollback"
    docker tag "$CUR_IMAGE" "subconverter-rollback:$STAMP"
    echo "        rollback tag: subconverter-rollback:$STAMP"
else
    echo "== 2/5 no existing container, nothing to back up"
fi

echo "== 3/5 recreating container"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --restart=always --network host \
    -v /etc/subconverter:/base -w /base "$IMAGE" >/dev/null

echo "== 4/5 waiting for the HTTP service"
VERSION=""
i=0
while [ "$i" -lt 40 ]; do
    VERSION="$(curl -sS -m 2 "http://127.0.0.1:$PORT/version" 2>/dev/null || true)"
    [ -n "$VERSION" ] && break
    i=$((i + 1))
    sleep 1
done

if [ -z "$VERSION" ]; then
    echo "!! service did not come up; recent logs:"
    docker logs "$NAME" 2>&1 | tail -20
    echo "!! roll back with: docker rm -f $NAME && docker run -d --name $NAME --restart=always --network host -v /etc/subconverter:/base -w /base subconverter-rollback:$STAMP"
    exit 1
fi

echo "== 5/5 deployed"
echo "   version : $VERSION"
echo "   image   : $IMAGE"
echo "   rollback: subconverter-rollback:$STAMP"
docker ps --filter "name=^$NAME$" --format '   running : {{.Names}} {{.Image}} {{.Status}}'
echo
echo "Next: verify the conversion keeps the subscription's own sections:"
echo "  sh scripts/verify-preserve.sh"
