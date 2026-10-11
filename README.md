# 三段式不用流体云

LSPosed 模块。拨动一加的三段式开关时，响应界面不用流体云胶囊，回落成 ColorOS 的经典弹窗；**其余场景的流体云完全不受影响**。

## 它解决的问题

OShin（O神）里有个「强制关闭流体云」开关，能让三段式开关退回经典弹窗 —— 但它是**全局**的，整机所有流体云一起消失。

这个模块只掐三段式那一条路径。

## 前提

- OnePlus 12 / ColorOS 16（开发时基于 `PJE110_16.0.5.701`，SystemUI `16.00.12`）
- LSPosed
- **OShin 里的「强制关闭流体云」必须是关的**，否则流体云本来就全局停摆，看不出区别

## 原理

ColorOS 的流体云内部代号是 **seedling**（幼苗）。`SystemUI` 里三段式的整个判断只有一处：

`com.oplus.systemui.opthreekey.tips.OpThreekeyDialogImpl` 的 `showH()`：

```java
if (seedlingPluginManager.isPluginAvailable) {
    mOpThreeKeySeedling.updateThreeKeySeeding(ctx, getThreeKeyStateForSeedling());
    h.obtainMessage(2, 1, 0).sendToTarget();   // 立刻 dismiss 经典弹窗
    return;
}
// ↓ 只有插件不可用时才走这里
rescheduleTimeoutH();
mDialog.show();
```

其中 `updateThreeKeySeeding()` 是全 dex 里唯一发送 `ringModeEvent` 的地方，
最终交给 `OplusSeedlingService` 渲染成胶囊。

模块做法：hook 住 `showH`，在它执行的那一瞬间把
`SeedlingPluginManager.isPluginAvailable` 按成 `false`，方法返回后再还原。

- 三段式 → 掉进 else 分支 → 经典弹窗
- 别处的流体云 → 因为立刻还原了，完全不知情

`SeedlingPluginManager` 是全局单例，所以有个极短的改写窗口，
但整个 `showH` 是主线程上的同步调用，期间没有其他主线程代码能观察到。

### 两个踩过的坑

**1. 不能按名字找 `showH`。**
它是 Kotlin 给内部类 `H` 生成的合成方法，dex 里的真名是 `-$$Nest$mshowH` ——
带 `-` 前缀，连合法的 Java 标识符都不是（jadx 会显示成 `m248$$Nest$mshowH`，
那个序号每次编译都在变）。而且 `-$$Nest$m` 这个前缀在别的类里同样出现，
`VolumeDialogImplSubDisplay` 就有一个同名同签名的。
所以按签名特征找：`static` + 返回 `void` + 参数恰好是 `(OpThreekeyDialogImpl, int)`。
该类静态方法总共只有它和 `<clinit>`，不会撞。

**2. 日志会骗人。**
`OplusSeedlingService: SeedlingDataManager-->setTip: ...RingModeTip... eventCode=ringModeEvent`
看着像流体云被触发了，其实那行夹在 `BaseService-->onCreate` / `onBind` 中间，
同一毫秒里 `RingModeTip`/`FlashlightTip`/`DndTip`/`MediaControlTip` 四个一起注册 ——
是服务初始化批量注册事件处理器，不是真触发。
验证要看的是 `OpThreekeyDialogImpl-->mDialogView onViewAttachedToWindow`
（经典弹窗渲染）和 `OplusSeedlingService` 什么时候 `onCreate`。

## 构建

```bash
./build.sh
adb install -r build/module.apk
```

手搓构建，不用 Gradle。工具链默认借 `../lsposed-tutorial/tools/`
（kotlinc 2.4.20 + LSPosed api-82），要搬走的话设 `TOOLS_DIR` 环境变量。
签名的钥匙同理借 `../lsposed-tutorial/debug.keystore`，设 `KEYSTORE` 可覆盖。

## 装上之后

manifest 里声明了 `xposedscope`，LSPosed 会自动勾上「系统界面」作用域，
装完**重启一次 SystemUI** 就生效：

```bash
adb shell su -c 'killall com.android.systemui'
```

（在 LSPosed 里也能手动确认：模块 → 作用域 → 系统界面。）

确认模块进来了：

```bash
adb logcat | grep "三段式无流体云"
```

应该看到 `已挂上 -$$Nest$mshowH(OpThreekeyDialogImpl, int)`，
第一次真正生效后还会再打一条 `已生效`。

## 失效了怎么办

直接看日志里有没有 `已挂上`：

- **没有** → hook 没挂上，多半是 ColorOS 升级后类名/签名变了
- **有 `已挂上` 但行为没变** → `isPluginAvailable` 那个判据变了

两种都去 `showH` 里重新找判据。反编译用 jadx：

```bash
# SystemUI 的 dex 在 /system_ext/priv-app/SystemUI/SystemUI.apk
# 三段式相关类在 classes6.dex，包名 com.oplus.systemui.opthreekey
```
