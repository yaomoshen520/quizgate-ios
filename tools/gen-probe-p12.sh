#!/usr/bin/env bash
# 生成一枚一次性自签名 PKCS#12，落到 App/Resources/QuizGateProbe.p12。
#
# 为什么在 CI 里现生成而不是入库：这是公开仓库，私钥一旦提交就永久泄露。
# 这枚钥匙的唯一用途是让 VPN 探测配置能通过「必须有身份数据」那一格校验，
# 不进任何真实握手，所以它必须、也只需要是当场生成当场用完的。
#
# .p12 已在 .gitignore 里，本脚本在本机跑也不会污染工作区。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/App/Resources/QuizGateProbe.p12"
mkdir -p "$root/App/Resources"

# 3DES + SHA1 是刻意选的：OpenSSL 3 默认给 AES-256 + SHA-256，而 iOS 的
# SecPKCS12Import 对老配方最宽容。macOS runner 上的 openssl 可能是 brew 的
# OpenSSL 3，也可能是系统 LibreSSL，两边都认这三个开关，所以显式钉死。
# 不用 -legacy：那是 OpenSSL 3 独有的，LibreSSL 直接报 unknown option。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 一律在临时目录里用相对文件名：Windows 上的 Git Bash 会把绝对 POSIX 路径
# 交给原生 openssl.exe 之前先改写一遍（/CN= 那条也被同样改写），而 runner 上
# 没有这层转换。相对路径两边行为一致，最后一份 mv 交给 shell 自己搬。
# MSYS_NO_PATHCONV 只在 Git Bash 下有含义，在 macOS 上是没人读的环境变量。
(
  cd "$tmp"
  MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 30 -subj "/CN=QuizGateProbe"
  MSYS_NO_PATHCONV=1 openssl pkcs12 -export \
    -inkey key.pem -in cert.pem -name QuizGateProbe -out probe.p12 \
    -passout pass:quizgate \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
)
mv "$tmp/probe.p12" "$out"

# 反面哨兵：写出来了不等于读得回去。Swift 那边只带一句「资源缺失」的日志，
# 拿不到 p12 的包和身份被拒的包在日志里长得一模一样，所以在这里就拦掉。
# 读回也放在临时目录里做，理由同上。
(cd "$tmp" && cp "$out" ./back.p12 \
  && MSYS_NO_PATHCONV=1 openssl pkcs12 -in back.p12 -nokeys \
       -passin pass:quizgate -info -nomacver >/dev/null)
ls -l "$out"
echo "probe p12 ready"
