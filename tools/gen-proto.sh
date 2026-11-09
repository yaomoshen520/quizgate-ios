#!/usr/bin/env bash
# 由同一份 .proto 生成 Swift 消息类型。需要 macOS 或 Linux + protoc + protoc-gen-swift。
#   brew install protobuf swift-protobuf
#   bash tools/gen-proto.sh [-ServerRoot /path/to/anti-addiction]
#
# 生成物落在 Kit/Sources/Generated/，已 gitignore：每次构建现生成，避免和后端协议漂移。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
proto_dir="$root/proto"
out="$root/Kit/Sources/Generated"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -ServerRoot)
      # 协议的唯一真源在后端仓库。传了这个参数就先把那份拷过来，再生成。
      cp "$2/proto/quizgate.proto" "$proto_dir/quizgate.proto"
      shift 2
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

for tool in protoc protoc-gen-swift; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少 $tool。macOS 上执行：brew install protobuf swift-protobuf" >&2
    exit 1
  fi
done

mkdir -p "$out"
# FileNaming=DropPath：类型名形如 Quizgate_RuleSnapshot，不带目录前缀。
# Visibility=Public：Kit 是静态库，App 与 extension 要能直接用这些类型。
protoc \
  --proto_path="$proto_dir" \
  --swift_out="$out" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  "$proto_dir/quizgate.proto"

count=$(find "$out" -name '*.pb.swift' | wc -l | tr -d ' ')
echo "已生成 $count 个 Swift 文件 → $out"