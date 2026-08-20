# image-pusher

将公开 Docker/OCI 镜像复制到指定镜像仓库，并可选通知明道云 HAP Webhook。当前版本支持：

- 公开源镜像
- 目标仓库推送，例如阿里云容器镜像服务
- `amd64`、`arm64` 或多架构 manifest
- GitHub Actions 手动触发
- `master` 分支推送自动触发 Release
- amd64/arm64 独立并行打包
- 可选生成各架构 Docker `.tar.gz` 镜像包
- 可选创建 GitHub Release
- 可选通知明道云 HAP Webhook
- JSON 镜像清单模板，供后续批量执行扩展

## 快速开始

在 GitHub 项目中进入 `Actions → Image Make → Run workflow`，按需选择操作：

| 操作 | 用途 |
| --- | --- |
| `push` | 复制源镜像到目标仓库，可选择是否生成 Release 包 |
| `release` | 只打包 `images.json` 中已有的镜像并创建 Release |
| `push-and-release` | 复制镜像后，同时为目标镜像生成 Release 包 |

workflow 参数：

以下内容也会显示在 GitHub 的 `Run workflow` 表单字段说明中。字段名后面的模式表示该字段只在对应模式下生效。

| 参数 | 示例 | 说明 |
| --- | --- | --- |
| `operation` | `push` | 操作模式 |
| `image` | `centos:7.9.2009` | 源镜像地址，当前默认不需要认证 |
| `target_image` | `registry.cn-hangzhou.aliyuncs.com/acme/centos:7.9.2009` | 目标镜像地址；`publish=true` 时必填 |
| `platforms` | `amd64` 或 `amd64,arm64` | 要复制的平台 |
| `publish` | `true` | 是否推送到目标仓库 |
| `package` | `false` | 是否生成 Docker 镜像归档并创建 Release |
| `notify_hap` | `false` | 是否发送 HAP Webhook |
| `manifest_file` | `images.json` | `release` 模式使用的已有镜像清单 |

### Run workflow 页面怎么填写

进入 `Actions → Image Make → Run workflow` 后，先选择 `master` 分支，再根据实际目的选择操作。

#### 只推送镜像：`push`

例如把 Docker Hub 的 CentOS 镜像复制到阿里云：

| 页面字段 | 填写值 |
| --- | --- |
| Select the operation | `push` |
| Source image for push mode | `centos:7.9.2009` |
| Target image for push mode | `registry.cn-hangzhou.aliyuncs.com/你的命名空间/centos:7.9.2009` |
| Architectures for push mode | `amd64`，或 `amd64,arm64` |
| Push the image to the target registry | 勾选 |
| Create Docker archives in push mode | 不勾选 |
| Notify HAP Webhook after completion | 按需勾选 |
| Existing image manifest for release mode | 保持 `images.json`，本模式不使用 |

此模式只复制镜像，不生成 Release 压缩包。

#### 只创建镜像 Release：`release`

适用于镜像已经存在于目标仓库，只需要下载并打包。现在有两种填写方式：

方式一：直接在表单填写一个镜像（适合临时打包）：

| 页面字段 | 填写值 |
| --- | --- |
| Select the operation | `release` |
| Source image for push mode | `registry.cn-hangzhou.aliyuncs.com/hap-mdy/linux-tools-amd64:1.0-alpine` |
| Architectures for push mode | `amd64` |
| Existing image manifest for release mode | 保持 `images.json` 即可，填写了镜像时不读取该文件 |

此时 workflow 会直接拉取上述镜像，生成类似下面的归档：

```text
linux-tools-amd64_1.0-alpine.tar.gz
```

方式二：批量处理清单：

| 页面字段 | 填写值 |
| --- | --- |
| Select the operation | `release` |
| Source image for push mode | 留空 |
| Target image for push mode | 留空 |
| Architectures for push mode | 保持默认值，本模式不使用 |
| Push the image to the target registry | 不勾选 |
| Create Docker archives in push mode | 不勾选，本模式自动打包 |
| Notify HAP Webhook after completion | 按需勾选 |
| Existing image manifest for release mode | `images.json` |

`images.json` 中的每个镜像都会被按架构打包，并创建一个以 `release_name` 命名的 Release。直接填写镜像时，Release 名称根据镜像最后的名称和 tag 自动生成。

#### 推送后立即创建 Release：`push-and-release`

填写方式与 `push` 相同，但选择：

```text
Select the operation: push-and-release
Push the image to the target registry: 勾选
```

该模式会先复制镜像，再从目标镜像生成各架构 `.tar.gz`，最后创建 Release；即使不勾选 `Create Docker archives in push mode`，也会自动打包。

说明：`release` 模式不读取 Source image、Target image 和 Architectures 字段；`push` 模式不读取 `images.json`。未启用的步骤会在 Actions 页面显示对应的 skipped summary。

向 `master` 分支推送代码时，workflow 会自动使用 `release` 模式，读取默认的 `images.json`，为清单中的已有镜像创建 Release。自动触发没有表单输入，不会执行源镜像复制，也不会自动发送 HAP 通知；需要手动推送镜像时，请使用 `Run workflow`。

Release 构建流程与 builder 项目一致，按阶段执行：

```text
Resolve release configuration
             |
       +-----+-----+
       |           |
   Build amd64  Build arm64
       |           |
       +-----+-----+
             |
       Create Release
             |
       Sync Release to HAP
```

模式参数的关系：

- `push`：使用 `image`、`target_image`、`platforms`；`package=true` 时会把推送后的 `target_image` 打包。
- `release`：如果填写了 `image`，直接打包该镜像，并使用 `platforms` 选择架构；如果 `image` 留空，则读取 `manifest_file` 中的清单。
- `push-and-release`：使用 `image`、`target_image`、`platforms`，并强制生成 Release 包；此时即使 `package=false` 也会打包。

第一次测试建议使用：

```text
image: centos:7.9.2009
target_image: registry.cn-hangzhou.aliyuncs.com/your-namespace/centos:7.9.2009
platforms: amd64
publish: true
package: false
```

源镜像必须实际包含所选平台。如果源镜像没有 `arm64` manifest，就不能选择 `amd64,arm64`。

## 目标仓库认证

在 GitHub 项目中配置：

Repository variable：

```text
REGISTRY=registry.cn-hangzhou.aliyuncs.com
```

Repository secrets：

```text
REGISTRY_USERNAME=阿里云镜像仓库用户名
REGISTRY_PASSWORD=阿里云镜像仓库密码或访问凭证
```

Workflow 会先执行 `docker login`，然后使用 Docker Buildx 将源镜像的 manifest 和 layer 复制到目标仓库。

## HAP Webhook

在明道云中创建「Webhook 触发」工作流，复制 Webhook 地址，然后配置 GitHub Secret：

```text
HAP_WEBHOOK_URL=https://你的明道云Webhook地址
```

镜像推送完成后，脚本会发送 POST JSON：

```json
{
  "event": "image_pushed",
  "source_image": "centos:7.9.2009",
  "target_image": "registry.example.com/acme/centos:7.9.2009",
  "digest": "sha256:...",
  "platforms": {
    "amd64": true,
    "arm64": false
  },
  "release_package": false
}
```

建议在 HAP Webhook 的“从请求样例生成”中，先使用 Actions 发送一次测试请求，再配置后续工作流节点，将字段写入工作表。明道云 Webhook 默认只要 URL 可访问即可请求；如果开启应用授权，再配置：

```text
HAP_WEBHOOK_APP_KEY=你的AppKey
HAP_WEBHOOK_SIGN=你的Sign
```

当前版本接受预先准备好的 `AppKey` 和 `Sign`，尚未自动计算签名。明道云官方说明见：[Webhook 触发工作流](https://help.mingdao.com/workflow/trigger-by-webhook/)。

## 镜像清单

[images.example.json](images.example.json) 是完整配置模板，包含：

- `version`：清单版本
- `defaults`：默认架构、是否推送、是否打包、是否通知 HAP
- `images`：镜像列表
- `image`：源镜像
- `target`：目标镜像
- `platforms.amd64` / `platforms.arm64`：架构开关
- `publish`：当前镜像是否推送
- `package`：当前镜像是否生成 Release 归档
- `notify_hap`：当前镜像是否通知 HAP
- `source_auth`：源仓库认证开关，当前版本保留字段，尚未实现源仓库登录

重要：当前 workflow 不会自动读取 `images.example.json`，它只是配置格式样例。`release` 模式填写 `image` 时直接处理该镜像；`image` 留空时才读取 `manifest_file` 指定的清单，默认是 `images.json`，并逐个处理其中的 `images` 条目；`push` 模式仍然一次处理 workflow 输入中的一个镜像。

## 本地运行

依赖 Docker、Docker Buildx、Python 3 和 curl：

```bash
SOURCE_IMAGE=centos:7.9.2009 \
TARGET_IMAGE=registry.example.com/acme/centos:7.9.2009 \
PLATFORMS=amd64 \
PUBLISH=true \
PACKAGE=false \
bash scripts/push-images.sh
```

变量说明：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SOURCE_IMAGE` | 无 | 必填，源镜像 |
| `TARGET_IMAGE` | 空 | 目标镜像，推送时必填 |
| `PLATFORMS` | `amd64,arm64` | `amd64`、`arm64` 或逗号分隔组合 |
| `PUBLISH` | `true` | 是否推送目标仓库 |
| `PACKAGE` | `false` | 是否生成镜像包 |
| `OUTPUT_DIR` | `release-assets` | 输出目录 |
| `NOTIFY_HAP` | `true` | 是否发送 HAP 通知 |
| `HAP_WEBHOOK_URL` | 空 | 填写后发送 HAP 通知 |

## Release 产物

当 `package=true` 时，打包来源是已经推送到目标仓库的 `TARGET_IMAGE`，不是源镜像 `SOURCE_IMAGE`。实际流程是：

1. 从 `SOURCE_IMAGE` 复制到 `TARGET_IMAGE`
2. 按架构从 `TARGET_IMAGE` 执行 `docker pull`
3. 对拉取的 `TARGET_IMAGE` 执行 `docker save`
4. 使用 gzip 生成 `.tar.gz`

因此 `package=true` 必须同时满足：

- `publish=true`
- `target_image` 已填写
- 目标镜像仓库认证正确
- 目标镜像包含所选架构

每个选定架构会生成一个 Docker save 压缩包，例如：

```text
release-assets/centos_7.9.2009_amd64.tar.gz
release-assets/image-manifest.json
```

包名只使用镜像最后一段的名称和 tag，不包含 registry、仓库路径或分支路径：

- 单架构：`镜像名_tag.tar.gz`
- 同一个镜像同时打包多个架构：`镜像名_tag_架构.tar.gz`

例如 `registry.example.com/acme/centos:7.9.2009` 只打包 amd64 时，包名为 `centos_7.9.2009.tar.gz`；同时打包 amd64 和 arm64 时，分别为 `centos_7.9.2009_amd64.tar.gz` 和 `centos_7.9.2009_arm64.tar.gz`。

`image-manifest.json` 是构建清单，记录源镜像、目标镜像、digest、平台、生成时间、仓库、提交号、Release tag，以及每个包的架构、文件名、大小和 SHA256。

Workflow 会自动创建名为 `image-<run_number>` 的 GitHub Release，并上传 `release-assets/*`。

## 仅为已有镜像创建 Release

如果镜像已经存在于目标仓库，不需要再次执行源镜像复制，可以使用：

`images.json`

当前配置的两个镜像为：

| 架构 | 镜像 |
| --- | --- |
| `arm64` | `registry.cn-hangzhou.aliyuncs.com/hap-mdy/linux_arm64_kafka-ui:main` |
| `amd64` | `registry.cn-hangzhou.aliyuncs.com/hap-mdy/kafka-ui:main` |

这两个镜像会按同一个逻辑镜像 `kafka-ui:main` 处理，Release 名称和 tag 为：

```text
kafka-ui_main
```

对应的架构包为：

```text
kafka-ui_main_arm64.tar.gz
kafka-ui_main_amd64.tar.gz
```

选择 `Actions → Image Make → Run workflow`，将 `operation` 设置为 `release`，workflow 会直接对 `images.json` 中的每个镜像执行：

```text
docker pull --platform ... IMAGE
docker save IMAGE | gzip -9 > release-assets/镜像名_tag[_架构].tar.gz
sha256sum release-assets/*.tar.gz
创建 GitHub Release
```

这个流程不读取 `SOURCE_IMAGE`，也不会复制或推送镜像；Release 包的来源就是 `images.json` 中填写的两个现有镜像。目标仓库需要认证时，仍使用 `REGISTRY`、`REGISTRY_USERNAME`、`REGISTRY_PASSWORD`。

## 目录结构

```text
image-pusher/
├── .github/workflows/image-make.yml
├── images.json
├── images.example.json
├── scripts/create-release.sh
├── scripts/push-images.sh
├── tests/self-check.sh
└── README.md
```

## 当前限制

- 源仓库认证尚未实现，当前先支持公开源镜像。
- `push` 模式当前一次处理一个镜像；`release` 模式支持按 `images.json` 批量打包。
- HAP `Sign` 当前需要外部预先生成，暂未自动计算。
- `package=true` 会分别拉取每个架构并生成归档，文件可能较大。
