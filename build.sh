#!/usr/bin/env bash
# 构建 LSPosed 模块（手搓，不用 Gradle）。
#
# 依赖只有两样：
#   1. Android SDK 的 build-tools + platform（下面的 SDK 变量指向它）
#   2. Kotlin 编译器 —— 首次构建会自动从 Maven Central 下载到 ./tools/
#
# 首次构建要下 ~63 MB（Kotlin 编译器本体 56 MB），之后就走缓存。
# 这些 jar 不入仓库：编译器太大，而且 Maven 上有官方发布，下回来比塞进 git 干净。
#
# 注意：Xposed API（tools/api-82.jar）是**随仓库提交**的 —— 它只有 25 KB，
#       而且官方没有稳定的下载地址，自己下反而麻烦。
#       它是 compileOnly：只用来编译，绝不能打进 APK，运行时的 API 由 LSPosed 框架注入。
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
BT="$SDK/build-tools/34.0.0"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${TOOLS_DIR:-$HERE/tools}"
OUT="$HERE/build"

[ -f "$ANDROID_JAR" ] || {
    echo "找不到 $ANDROID_JAR"
    echo "装 Android SDK 的 build-tools;34.0.0 和 platforms;android-34，"
    echo "或者设 ANDROID_SDK_ROOT 指向你的 SDK 目录。"
    exit 1
}

# ───────── 工具链：缺什么下什么 ─────────
mkdir -p "$TOOLS"
MAVEN=https://repo1.maven.org/maven2
fetch() {   # fetch <url> <目标文件>
    [ -f "$2" ] && return 0
    echo "  下载 $(basename "$2")"
    curl -fL --progress-bar -o "$2.part" "$1"
    mv "$2.part" "$2"
}
echo "[0/6] 准备工具链（首次会下 ~63 MB，之后跳过）"
fetch "$MAVEN/org/jetbrains/kotlin/kotlin-compiler-embeddable/2.4.20/kotlin-compiler-embeddable-2.4.20.jar" "$TOOLS/kotlin-compiler-embeddable-2.4.20.jar"
fetch "$MAVEN/org/jetbrains/kotlin/kotlin-stdlib/2.4.20/kotlin-stdlib-2.4.20.jar" "$TOOLS/kotlin-stdlib-2.4.20.jar"
fetch "$MAVEN/org/jetbrains/kotlin/kotlin-daemon-embeddable/2.4.20/kotlin-daemon-embeddable-2.4.20.jar" "$TOOLS/kotlin-daemon-embeddable-2.4.20.jar"
fetch "$MAVEN/org/jetbrains/kotlin/kotlin-script-runtime/2.4.20/kotlin-script-runtime-2.4.20.jar" "$TOOLS/kotlin-script-runtime-2.4.20.jar"
fetch "$MAVEN/org/jetbrains/kotlin/kotlin-reflect/2.4.20/kotlin-reflect-2.4.20.jar" "$TOOLS/kotlin-reflect-2.4.20.jar"
fetch "$MAVEN/org/jetbrains/annotations/26.0.2/annotations-26.0.2.jar" "$TOOLS/annotations-26.0.2.jar"
fetch "$MAVEN/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.8.0/kotlinx-coroutines-core-jvm-1.8.0.jar" "$TOOLS/kotlinx-coroutines-core-jvm-1.8.0.jar"

KOTLIN_STDLIB="$TOOLS/kotlin-stdlib-2.4.20.jar"
XPOSED_API="$TOOLS/api-82.jar"
[ -f "$XPOSED_API" ] || { echo "缺 $XPOSED_API（应该随仓库提交，检查是不是被删了）"; exit 1; }

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
# 钥匙放在项目根目录，**不进仓库**（.gitignore 里有 *.keystore）。
# 必须放在 build/ 外面 —— build/ 每次都被整个删掉，钥匙放里面会被反复重新生成，
# 新钥匙装不上旧包（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
KS="${KEYSTORE:-$HERE/debug.keystore}"
if [ ! -f "$KS" ]; then
    echo "  没有签名钥匙，生成一个到 $KS"
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
