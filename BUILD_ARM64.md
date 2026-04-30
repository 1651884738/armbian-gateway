# NanoPi R2S (ARM64) 交叉编译指南

本文档记录了如何使用 Docker 将本 Haskell 智能网关项目快速交叉编译到 NanoPi R2S (aarch64 / ARM64) 架构的完整流程。

---

## 1. 原理说明
利用 Docker 的多架构支持（QEMU），在 x86_64 的电脑上模拟运行 ARM64 架构的 Debian 容器。
通过挂载项目代码和 `.cabal` 缓存文件夹，实现**在容器中编译、在电脑上存缓存、在 R2S 上跑程序**的完美闭环。由于使用了兼容的基础镜像，打出来的二进制包拷入 R2S 即可直接动态运行，无需任何其他配置。

## 2. 初次使用：环境准备与镜像构建
如果你是**换了一台新电脑**，需要依次执行：

**2.1 安装 Docker 与 QEMU 多架构支持**
```bash
# 1. 安装 Docker
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# 2. 将当前用户加入 docker 组（免 sudo 运行）
sudo usermod -aG docker $USER
newgrp docker

# 3. 安装 QEMU 多架构静态模拟器
sudo apt-get install -y qemu-user-static binfmt-support

# 4. 注册多架构节点
sudo docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

**2.2 构建专属的 ARM64 编译镜像**
利用项目根目录的 `Dockerfile.cross-arm64`，构建包含底层 C 库（如 SQLite）的编译镜像：
```bash
docker build -t r2s-builder -f Dockerfile.cross-arm64 --platform linux/arm64 .
```
*(注意：平时不要动这个镜像，除非你网关项目引入了除 SQLite 外的其它系统级 C 语言库)*

---

## 3. 日常工作流：秒级编译（🚀 最常用）
当你在电脑上写完 Haskell 代码，准备在 R2S 上进行真机测试时：

### 第一步：启动编译容器
在项目根目录运行下面这条“终极命令”进入容器：
```bash
docker run --rm -it \
  -v $(pwd):/app \
  -v ~/.cabal-docker-arm64:/root/.cabal \
  --platform linux/arm64 \
  r2s-builder /bin/bash
```
*(注：这里巧妙地把 `~/.cabal-docker-arm64` 映射成了容器的缓存，防止以后每次编译都要重下几百兆的 Haskell 包)*

### 第二步：执行编译
进入容器后，直接运行编译命令：
```bash
# （仅首次使用该环境，或修改了包依赖时才需要跑）
cabal update

# 编译整个网关主程序：
cabal build r2s-geteway

# 或者只编译 MQTT 测试小工具：
cabal build test-mqtt
```

### 第三步：提取产物上传真机
编译成功后，敲击 `Ctrl+D` 退出容器。
由于 Haskell 编译输出目录较深，可以通过下面的搜索命令快速找到可执行文件：
```bash
find dist-newstyle -type f -name "r2s-geteway"
find dist-newstyle -type f -name "test-mqtt"
```

然后通过 `scp` 发送到你的 R2S 上（举例）：
```bash
scp dist-newstyle/...路径.../test-mqtt root@你的R2S_IP:/root/
```

登录 R2S 赋予执行权限并运行：
```bash
chmod +x test-mqtt
./test-mqtt
```
