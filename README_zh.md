<!-- Keep this file synchronized with README.md. -->

# Auto Script for GitHub Setup and Push

[English](README.md)

Auto Script for GitHub Setup and Push 是一个面向所有人的集中式 Bash 工具，让本地改动以更少操作、更可靠的身份验证上传到 GitHub。完整功能统一由一个 `git-auto.sh` 中央脚本维护，每个具体项目只需要一个很小的本地 `g.sh` 启动器。

日常只需记住四个入口：

- `./g.sh`：必要时设置当前项目，然后提交并上传。
- `./g.sh new`：新增或导入 GitHub 账号，并可继续连接当前项目。
- `./g.sh update`：GitHub 用户名、仓库名或仓库归属变化后，同步本机设置。
- `./g.sh menu`：打开账号、修复、偏好设置和高级工具。

SSH 身份、账号核验、项目提交身份、发布提交说明、上游分支和严格推送身份均由脚本在内部处理。

## 整体结构

整个项目由一个中央引擎、一份私人配置和每个项目各自的启动器组成：

```text
git-auto/
|-- git-auto.sh
|-- g.sh              公开且可以直接复制的轻量启动器
|-- README.md
|-- README_zh.md
|-- CHANGELOG.md
|-- CHANGELOG_zh.md
|-- tests/
|-- private/          仅保留在本机；自动创建且不会进入 Git
|   `-- config.txt
`-- sidenote/         本机 Agent 笔记；不会进入 Git

your-project/
|-- g.sh              自动生成的轻量启动器；仅保留在本机
`-- 项目文件...
```

`git-auto.sh` 是唯一的完整实现。不再区分公开脚本和个人脚本，也不在可执行代码中重复保存账号区块。中央引擎更新一次，所有已生成启动器都会使用新功能。

## 第一次使用

把公开项目放在准备长期保存中央脚本的位置，然后运行：

```bash
chmod +x git-auto.sh
./git-auto.sh
```

第一次在交互式终端中运行时，脚本会询问一次界面语言并创建 `private/config.txt`。中央管理菜单可以为指定项目自动创建轻量级 `g.sh`。仓库根目录也直接提供一份公开的 `g.sh`，因此手动复制粘贴同样可以使用：

```bash
cp g.sh /path/to/your-project/g.sh
```

以后进入具体项目，只使用下面四个短命令：

```bash
./g.sh
./g.sh new
./g.sh update
./g.sh menu
```

不需要设置 Shell alias、修改 PATH、安装软件包，也不会创建额外的应用专用用户配置目录。

## 中央管理菜单

在中央文件夹中运行 `./git-auto.sh` 会打开管理菜单，可用于：

- 为指定项目创建或修复 `g.sh`。
- 把 GitHub 账号添加到共享私人配置。
- 检查并修复已经配置的 GitHub SSH 身份。
- 修改所有项目共用的界面语言和显示模式。
- 进入高级工具，包括历史发布版本导入。

在中央文件夹中运行 `./git-auto.sh new` 可以直接进入账号设置。与具体项目有关的操作仍通过该项目自己的 `g.sh` 完成。

## 轻量级项目启动器

公开的 `g.sh` 不包含 GitHub 账号、SSH、版本、提交或历史重建业务逻辑。它会确定自身所在的项目文件夹，并依次从项目本地 Git 设置、相邻或上级目录中的 `git-auto/`、常见用户目录和 `PATH` 自动寻找中央脚本。全部自动方式均未找到时，才会询问 `git-auto.sh` 的位置。

中央仓库根目录的 `g.sh` 是公开项目文件，不会被忽略。中央菜单把它复制到其他项目后，会将那个项目副本写入 `.git/info/exclude`，且不改动团队共享的 `.gitignore`。解析出的中央路径只保存在目标项目本地 `.git/config` 中；`g.sh` 自身始终保持通用，可以安全公开。

中央文件夹移动后，启动器会重新搜索，并可用中英文接受用户粘贴的新路径。也可以从新位置打开中央菜单修复项目启动器，无需重新设置项目或账号。

## 私人配置

所有个性化应用状态都保存在 `git-auto.sh` 旁边被 Git 忽略的 `private/config.txt`：

```text
language: zh
display-theme: auto

username: johnjoe
email: 123456+johnjoe@users.noreply.github.com

username: alice
email: alice@example.com
```

每个字段独占一行，账号之间用空行分隔。每个账号只有 GitHub 用户名和提交邮箱，提交显示名始终由 GitHub 用户名自动确定。

中央引擎会自动创建 `private/`，并把目录和配置文件权限分别限制为只有当前用户可以访问和读写。保存时采用原子替换，不会在其中写入私钥、密钥口令、访问令牌或登录密码。

其他人使用公开项目时，也会自动得到各自独立且被忽略的 `private/` 文件夹，不再需要制作个性化脚本副本。

## 运行 g.sh 后会发生什么？

默认流程按照用户能够理解的下一步组织：

1. 把启动器所在文件夹作为准确的项目根目录。
2. 当前文件夹还不是 Git 仓库时自动初始化。
3. 从中央私人配置读取所有可用账号。
4. 只有在无法识别 `origin` 时才询问仓库地址。
5. 能够明确匹配账号时自动选择，否则只显示已配置用户名。
6. 保存绑定前核实具体私钥、GitHub 登录用户名和仓库访问权限。
7. 暂存改动并展示建议提交说明。
8. 用户确认后才创建提交。
9. 使用已经验证的账号和密钥上传当前分支。

已经完成的设置会自动识别并跳过。身份检查取消或失败时，不会写入不完整的项目绑定。

## GitHub 账号设置

`./g.sh new` 和中央账号菜单使用同一套引导：

1. 扫描 `~/.ssh/config` 及其 `Include` 文件，找出最终 `HostName` 为 `github.com` 的配置。
2. 解析候选密钥，并让 GitHub 返回该密钥实际登录的用户名。
3. 发现尚未写入 `private/config.txt` 的已验证账号时，优先询问是否导入。
4. 没有可复用身份时，只询问 GitHub 用户名和提交邮箱。
5. 创建独立 ED25519 密钥和无冲突的 SSH 配置。
6. 引导用户把公钥添加到正确的 GitHub 账号。
7. 经 GitHub 验证成功后才保存账号。

新连接默认使用 `github-USERNAME`。遇到冲突时会自动尝试 `-1`、`-2` 及后续数字。每个新建账号使用不同私钥；已经存在且验证成功的密钥会直接复用，不会重复创建。

隐私提交邮箱建议采用 GitHub 当前的 `ID+USERNAME@users.noreply.github.com` 格式，也可以填写已经在 GitHub 验证的其他邮箱。

## 多账号保护

共享私人配置让所有项目都能使用已经配置的账号，但每个仓库每次推送仍然只允许使用一个明确账号。

项目专属信息只保存在该仓库的 `.git/config`：用户名、邮箱、SSH 连接名、密钥文件和规范化后的 `origin`。每次网络操作前，脚本都会创建临时 SSH 包装程序，启用 `IdentitiesOnly=yes` 并固定选定私钥，SSH Agent 中的其他密钥不能静默成为备用身份。

组织仓库会绑定到明确选择的个人账号，不会把组织名称误当作登录身份。

## 仓库地址输入

仓库输入框可以识别并规范化常见 GitHub 格式：

```text
owner/repository
owner/repository.git
github.com/owner/repository
https://github.com/owner/repository
https://github.com/owner/repository/tree/main
https://github.com/owner/repository/blob/main/README.md
git@github.com:owner/repository.git
ssh://git@github.com/owner/repository.git
git clone https://github.com/owner/repository.git
gh repo clone owner/repository
```

查询参数、页面锚点、末尾斜杠、`.git` 和仓库内部页面路径都会自动去除。非 GitHub 地址会被明确拒绝，不会静默改写。

## 用户名或仓库发生变化

在 GitHub 上完成用户名修改、仓库改名或仓库转移后，在受影响项目中运行 `./g.sh update`。

脚本先询问哪项内容发生了变化，只收集相关的新信息。写入本机设置前，会确认原有密钥现在登录的是新用户名，并核实该账号能够访问准确的新仓库。用户名变化时继续使用原密钥，创建无冲突的新连接名，保留旧连接以免影响其他项目，同时更新共享私人账号记录、当前仓库的提交身份和 `origin` 拉取与推送地址。

这个更新流程不会修改项目文件、分支或提交历史。

## 提交说明和发布版本

每次真正创建提交前仍由用户确认。中央引擎会先展示暂存摘要，再给出建议说明。

已有仓库按照以下顺序发现发布版本：

1. 根目录 `package.json` 中的有效版本。
2. 根目录 `CHANGELOG`、`CHANGELOG.md` 或 `CHANGELOG.txt`。
3. 根目录其他 `CHANGELOG*` 语言版本；存在差异时采用最高有效版本。
4. 根目录没有可用变更日志时，递归扫描项目自有的 `CHANGELOG*` 并采用最高有效版本。
5. 根目录 `VERSION*` 文件。
6. 递归 `VERSION*` 文件。
7. 回退为 `Update`。

解析支持新版本在顶部或底部、常见英文和中文日期、预发布版本、构建信息、可选 `v` 前缀、方括号和多种 Unicode 破折号。递归查找会排除依赖、缓存、虚拟环境、构建和覆盖率目录。

## 导入历史发布版本

高级菜单可以从一组完整版本文件夹重新建立原本缺失的线性 Git 历史。

脚本会发现或接收版本映射，按照 SemVer 排序，并在临时仓库中为每个版本创建一个完整的 `Release X.Y.Z` 快照提交。新版已经删除的旧文件不会残留在新版快照中。正常隐藏文件和被忽略文件会保留，每一层的 `.git` 和 `.DS_Store` 都会排除。

存档版本缺少根目录 `.gitignore` 时，用户可以在终端直接粘贴一份通用规则。它只会添加到缺失的重建快照，不会写回原始版本文件夹。

流程会检查疑似敏感文件和超大文件，可创建轻量版本标签，展示 `git log --oneline --reverse`，并在上传前验证选定的 GitHub 身份。替换已有远端 `main` 必须明确确认，并使用精确的 `--force-with-lease`。脚本不会创建备份分支，也不会改动其他远端分支。

快照复制由中央引擎自行实现，不依赖 `rsync`。

## 语言、显示和无障碍体验

第一次运行默认选择英文，也可使用完整本地化的中文界面。选定语言统一应用于项目命令、中央管理、更新流程、高级工具、说明、提醒和错误信息，并可从任一菜单修改。

显示模式支持自动、深色、浅色和无颜色。自动模式优先读取终端背景信息，在 macOS 上也会参考系统外观。设置 `NO_COLOR` 或非交互输出时会关闭颜色。

整个界面只使用纯文字状态标签，不输出 Emoji 表情符号。

## 安全与本机状态

中央引擎只写入当前流程确实需要的位置：

- `private/config.txt`：共享的个人偏好与账号基本资料。
- `~/.ssh`：GitHub SSH 密钥和配置。
- 目标仓库的 `.git/config` 与 `.git/info/exclude`：本地账号绑定和启动器排除。
- 临时目录：严格 SSH 包装程序和历史版本重建仓库。

私钥不会复制到中央项目或 `private/config.txt`。普通推送绝不使用强制覆盖。历史导入始终保持原始发布文件夹不变。

## 运行要求和测试

- Bash 3.2 或更高版本。
- Git 与 OpenSSH 工具：`git`、`ssh`、`ssh-keygen`。
- 单文件 Bash 引擎使用的标准 POSIX/macOS 工具。
- 连接 GitHub 以验证身份和仓库权限的网络环境。

运行隔离测试：

```bash
./tests/test.sh
```

测试使用临时用户目录、私人配置、Git 仓库、SSH 配置和模拟 SSH 传输，不会读取真实私人配置，也不会改动真实 GitHub 仓库。

## 许可证

本项目尚未声明许可证。在明确授权之前，请勿假定拥有著作权法律默认范围之外的复用权利。
