#!/usr/bin/env bash
# 构建 LSPosed 模块（手搓，不用 Gradle）。
#
# 跟 lsposed-tutorial/first-module 的构建脚本基本一致，两处不同：
#   1. 工具链目录默认借 first-module 那一套（省 100 多 MB 重复下载），
#      想搬走的话设 TOOLS_DIR 环境变量指过去就行。
#   2. 多了一步 aapt2 compile —— 因为要用 res/ 里的 xposedscope 数组
#      （编译期资源，跟 Xposed API 一样只进 APK 的资源表，不是代码）。
#
# 注意：Xposed API 是 compileOnly —— 只用来编译，绝不能打进 APK，
#       运行时的 API 由 LSPosed 框架自己注入。
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
BT="$SDK/build-tools/34.0.0"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${TOOLS_DIR:-$HERE/../lsposed-tutorial/tools}"
KOTLINC_JAR="$TOOLS/kotlin-compiler-embeddable-2.4.20.jar"
KOTLIN_STDLIB="$TOOLS/kotlin-stdlib-2.4.20.jar"
XPOSED_API="$TOOLS/api-82.jar"
OUT="$HERE/build"

[ -f "$ANDROID_JAR" ] || { echo "找不到 $ANDROID_JAR"; exit 1; }
[ -f "$XPOSED_API" ]  || { echo "找不到 $XPOSED_API（设 TOOLS_DIR 指到工具链目录）"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/dex"

echo "[1/6] 编译资源（xposedscope）"
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"

echo "[2/6] kotlinc 编译（Xposed API 只在编译期挂，不进包）"
java -cp "$TOOLS/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-jdk -no-reflect \
    -classpath "$ANDROID_JAR:$KOTLIN_STDLIB:$XPOSED_API" \
    -jvm-target 1.8 \
    -d "$OUT/classes.jar" \
    $(find "$HERE/src" -name '*.kt')

echo "[3/6] d8 转 dex（只有我们自己的代码 + Kotlin 标准库）"
"$BT/d8" --lib "$ANDROID_JAR" --min-api 26 \
    --output "$OUT/dex" \
    "$OUT/classes.jar" "$KOTLIN_STDLIB"

echo "[4/6] aapt2 打包（-A assets 带上 xposed_init）"
"$BT/aapt2" link -o "$OUT/unsigned.apk" \
    -I "$ANDROID_JAR" \
    --manifest "$HERE/AndroidManifest.xml" \
    -A "$HERE/assets" \
    "$OUT/res.zip" \
    --min-sdk-version 26 --target-sdk-version 34

echo "[5/6] 把 dex 塞进 apk"
(cd "$OUT/dex" && zip -q "$OUT/unsigned.apk" *.dex)

echo "[6/6] 对齐 + 签名"
# 钥匙借用 lsposed-tutorial 那一把。同一把钥匙 = 能覆盖安装。
# 注意钥匙必须放在 build/ 外面 —— build/ 每次都被整个删掉，
# 钥匙放里面会被反复重新生成，新钥匙装不上旧包。
KS="${KEYSTORE:-$HERE/../lsposed-tutorial/debug.keystore}"
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -alias debug \
        -storepass android -keypass android \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=debug, O=test"
fi

"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
    --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/module.apk" "$OUT/aligned.apk"

echo
echo "==> 生成: $OUT/module.apk"
echo "==> 安装: adb install -r $OUT/module.apk"
