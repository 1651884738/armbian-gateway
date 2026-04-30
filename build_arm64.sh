#!/bin/bash
set -e

echo "================================================"
echo "🚀 开始跨架构编译 NanoPi R2S (ARM64) 固件..."
echo "================================================"

# 运行容器并传递内部执行脚本
docker run --rm -i \
  -v "$(pwd)":/app \
  -v ~/.cabal-docker-arm64:/root/.cabal \
  --platform linux/arm64 \
  r2s-builder /bin/bash -c "
    set -e
    echo '>> 1. 执行 Cabal Build (正在编译...)'
    cabal build
    
    echo '>> 2. 正在提取编译产物...'
    # 创建统一的产物输出目录
    mkdir -p out_bin
    
    # 查找并复制 r2s-geteway
    GATEWAY_BIN=\$(find dist-newstyle -type f -name 'r2s-geteway' | head -n 1)
    if [ -n \"\$GATEWAY_BIN\" ]; then
      strip \"\$GATEWAY_BIN\"
      cp \"\$GATEWAY_BIN\" out_bin/
      echo '  ✓ 成功提取主程序: out_bin/r2s-geteway (已瘦身)'
    fi

    # 查找并复制 test-mqtt
    MQTT_BIN=\$(find dist-newstyle -type f -name 'test-mqtt' | head -n 1)
    if [ -n \"\$MQTT_BIN\" ]; then
      strip \"\$MQTT_BIN\"
      cp \"\$MQTT_BIN\" out_bin/
      echo '  ✓ 成功提取测试工具: out_bin/test-mqtt (已瘦身)'
    fi
    
    echo '================================================'
    echo '🎉 编译且提取完毕！请查看宿主机的 out_bin/ 目录'
  "
