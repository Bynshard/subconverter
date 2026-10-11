---
name: subconverter-edge-deploy
description: >-
  改造并部署家庭网络里的 subconverter（Bynshard/subconverter fork）到 iStoreOS 路由器：
  先存档机场订阅原文，改代码、本地离线回归、推送 GitHub 触发 Actions 构建
  ghcr.io/bynshard/subconverter-edge 镜像、路由器 docker pull 重建容器、用
  离线回放 + mihomo 配置校验证明「订阅自带的 hosts/dns 等顶层段没有被转换丢掉」，
  必要时回滚。适用于：机场订阅转换后节点全不通/解析到错误 IP、转换结果里缺少
  hosts、要改 subconverter 转换行为、要升级路由器上的 subconverter 镜像。
---

# subconverter edge 改造与部署

## 何时用

- 机场订阅转换后节点异常：`hosts` 段丢失，假子域名被解析到公网 CDN 的错误 IP
- 需要修改 subconverter 的转换行为，并把它部署到 `192.168.100.1` 的 Docker 上
- 需要升级/回滚路由器上的 subconverter 镜像
- 需要核对「订阅自带的东西（hosts/dns/tun/…）是否被保留」

## 环境事实（不要重新探测，除非失败）

| 项 | 值 |
| --- | --- |
| 路由器 | `root@192.168.100.1`，iStoreOS 24.10.1 / OpenWrt，**aarch64** |
| 源码 / 构建机 | `192.168.100.141`，`/home/bynshard/subconverter`（本仓库，git remote 指向 `github.com/Bynshard/subconverter`，**公开仓库**） |
| 容器 | `subconverter`，镜像 `ghcr.io/bynshard/subconverter-edge:*-linux-arm64`，`--network host`，`-v /etc/subconverter:/base -w /base`，`--restart=always`，监听 `25500` |
| OpenClash | mihomo，配置 `/etc/openclash/clash-verge1.yaml`，调用 `http://192.168.100.1:25500/sub`，UA `clash.meta` |
| 镜像 tag | `sha-<7位sha>-linux-arm64`（固定）/ `edge-linux-arm64`（滚动） |
| 私有订阅地址 | `local/subscriptions.env`（开发机）/ `/etc/subconverter/local/subscriptions.env`（路由器），**已 git-ignore** |
| 离线回放样本 | `tmp/raw/*.txt`（开发机）/ `/etc/subconverter/replay/rama991-clash.yaml`（路由器） |

## 铁律

1. **先拉原文，再改任何东西。** 机场按 User-Agent 分流且有速率/时限：
   `clash.meta`/`Clash` → Clash YAML（含 `hosts`）；`Shadowrocket`/`Mozilla`/`curl` → base64；
   `clash-verge`/`mihomo`/`ClashforWindows` → 401。拿到原文后所有验证都能离线做。
2. **不要把 token / 节点密码 / 内网细节提交到 git。** 仓库是公开的。`docs/`、`local/`、`tmp/`
   已在 `.gitignore`；只提交 `src/`、`scripts/`、`README-docker.md`、`.gitignore`。
3. **测转换务必带对 UA**（`-A 'clash.meta'`），否则上游返回 base64，转换器认不出 Clash 配置，
   会误判成"没东西可保留"。
4. **切换 OpenClash 活动配置前，先确认生成的配置里 `hosts` 在**，否则等于把能用的配置换成废的。
5. 开发机到 GitHub 的 22 端口不通（fake-ip/路由），用 **HTTPS** 推送。

## 步骤

### 0. 存档订阅原文

```sh
cd /home/bynshard/subconverter
sh scripts/save-subscription.sh          # 读 local/subscriptions.env
# 挑出 Clash 那份（含 hosts/proxies），放到路由器供离线回放
ssh root@192.168.100.1 'mkdir -p /etc/subconverter/replay'
scp tmp/raw/<stamp>.clash_meta.txt root@192.168.100.1:/etc/subconverter/replay/rama991-clash.yaml
```

### 1. 改代码

主战场 `src/handler/interfaces.cpp`：`mergeSourceClashSections()` 及其三个键集合
（`sourceClashRegeneratedKeys` / `sourceClashAlwaysPreservedKeys` / `sourceClashDeploymentOwnedKeys`）。
语义与参数见 `docs/03-subconverter-fork.md`。

### 2. 本地编译 + 离线回归

```sh
cmake --build build -j"$(nproc)"
sh scripts/offline-regression.sh
```

必须 `RESULT: PASS`，且：套模板用例 `hosts` 条目数 == 原文条目数（本订阅 30）、`mixed-port=0`；
`preserve_source=false` 用例 `hosts=0`（反证开关有效）。

### 3. 推送

```sh
git add -A -- src scripts README-docker.md .gitignore
git commit -m "..."
git push https://github.com/Bynshard/subconverter.git HEAD:master
```

### 4. 等 CI

```sh
SHORT=$(git rev-parse --short=7 HEAD)
gh run list --limit 3
gh run watch <run-id> --exit-status     # 约 5 分钟；arm64 先完成
```

### 5. 部署

```sh
scp scripts/deploy-edge-image.sh scripts/verify-preserve.sh root@192.168.100.1:/root/subconverter-scripts/
ssh root@192.168.100.1 \
  "IMAGE=ghcr.io/bynshard/subconverter-edge:sha-$SHORT-linux-arm64 \
   sh /root/subconverter-scripts/deploy-edge-image.sh"
```

脚本自动：拉镜像 → 旧镜像打 `subconverter-rollback:<时间戳>` → 按原规格重建容器 → 等 `25500` 就绪。

### 6. 验证（面板挂了也能做）

```sh
ssh root@192.168.100.1 'sh /root/subconverter-scripts/verify-preserve.sh'          # 离线回放
ssh root@192.168.100.1 'SOURCE=live sh /root/subconverter-scripts/verify-preserve.sh'  # 面板正常时
```

必须看到 `RESULT: PASS`，其中包含 `hosts mapping preserved (N entries)`、
`no mixed-port leaked`、`mihomo accepted the generated config`。

### 7. （面板可用时）让 OpenClash 用上新配置

先备份：`uci export openclash > /etc/openclash/backup/uci-openclash-$(date +%Y%m%d%H%M%S).txt`

```sh
uci set openclash.@config_subscribe[0].address='https://<新域名>/api/v1/trails/bolster?token=<token>'
uci set openclash.@config_subscribe[0].enabled='1'
uci commit openclash
/usr/share/openclash/openclash.sh <name>                     # 拉取该订阅
grep -c '^hosts:' /etc/openclash/config/<name>.yaml          # 必须 ≥1，否则停手
uci set openclash.config.config_path='/etc/openclash/config/<name>.yaml'
uci commit openclash && /etc/init.d/openclash restart
```

### 8. 回滚

```sh
ssh root@192.168.100.1 'docker rm -f subconverter && \
  docker run -d --name subconverter --restart=always --network host \
    -v /etc/subconverter:/base -w /base subconverter-rollback:<时间戳>'
```

## 关键坑位

- `main()` 会先 `setcd(argv[0])` 切到二进制所在目录找 `pref.toml`。用绝对路径启动会切到 `build/`，
  于是静默退回默认值并打印 `Unable to load preference settings as INI`。
  **用 `-f <pref路径>` 显式指定**。
- 命令行**没有**端口参数；端口来自 `pref.toml` 的 `[server] port` 或环境变量 `PORT`。
- 订阅原文是 `mixed-port: 7890`，模板渲染出的是 `port: 7890` + `socks-port: 7891`；
  无脑全量合并会导致同端口双重监听。合并必须跳过"部署自持键"。
- `INCLUDE_RULES=0` 的镜像里没有 `rules/`，运行时会有
  `Failed to fetch ruleset or ruleset is empty` 告警 —— 正常，规则走远程 URL。
- 上游 401 时先怀疑 UA 与 token，不要先改代码。

## 参考

- `docs/01-home-network.md` 拓扑
- `docs/02-subscription-pipeline.md` 链路与 `hosts` 问题剖析
- `docs/03-subconverter-fork.md` 改造细节与参数
- `docs/04-runbook.md` 完整 runbook
- `docs/05-verification.md` 验证方法与实测证据
