package com.threevits.nocapsule

import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 让「三段式开关」的响应界面不走流体云，回落成经典弹窗。
 *
 * ── 原理（ColorOS 16 / SystemUI 16.00.12，一加 12 实测） ──
 *
 * OpThreekeyDialogImpl.showH() 里只有一个岔路口：
 *
 *     isPluginAvailable == true   →  把状态交给 OpThreeKeySeedling，让流体云渲染，然后 return
 *     isPluginAvailable == false  →  走经典分支，mDialog.show()
 *
 * "seedling"（幼苗）就是流体云的内部代号——那个插件不可用时，整机所有流体云
 * 一起消失，这正是 OShin「强制关闭流体云」在做的事（它是全局的）。
 *
 * 我们只想要其中一半：三段式走经典，别处流体云照常。
 * 做法是在 showH 执行的那一瞬间，把这个布尔值按成 false，让它掉进经典分支，
 * 方法返回后再还原。于是：
 *
 *     三段式开关      → 经典弹窗（想要的效果）
 *     其他一切流体云  → 完全不受影响
 *
 * ── 为什么不按方法名找 showH ──
 *
 * showH 是 Kotlin 给内部类 H 生成的合成方法，dex 里的真名是
 * `-$$Nest$mshowH`：带 `-` 前缀，连合法的 Java 标识符都不是，
 * 而且 `-$$Nest$m` 这个前缀在别的类里同样重复出现
 * （VolumeDialogImplSubDisplay 就有一个同名同签名的），
 * 所以名字和前缀都不能当判据。这里按签名特征找：
 * static + 返回 void + 参数恰好是 (OpThreekeyDialogImpl, int)。
 * 该类的静态方法总共只有它和 <clinit>，不会撞。
 *
 * ── 为什么不会 NPE ──
 *
 * 经典分支要用 mDialog，而它由 initDialog() 建立。initDialog() 是在
 * OpThreekeyComponent 的构造里**无条件**调用的（同处还给 mWindowType 赋了
 * 2020），跟插件可不可用无关，所以 mDialog 在任何一次 showH 之前必然已就绪。
 */
class HookEntry : IXposedHookLoadPackage {

    /** 只在第一次真正生效时打日志，避免每次拨动开关都刷屏。 */
    private val logged = AtomicBoolean(false)

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {

        // 这个模块只关心 SystemUI 进程
        if (lpparam.packageName != PKG_SYSTEMUI) return

        val implClass = try {
            XposedHelpers.findClass(CLS_DIALOG_IMPL, lpparam.classLoader)
        } catch (t: Throwable) {
            XposedBridge.log("[$TAG] 找不到 $CLS_DIALOG_IMPL，系统版本大概对不上，模块未生效")
            return
        }

        val showH = findShowH(implClass)
        if (showH == null) {
            XposedBridge.log("[$TAG] 在 $CLS_DIALOG_IMPL 里找不到 showH 的签名，系统版本大概对不上，模块未生效")
            return
        }

        XposedBridge.hookMethod(showH, object : XC_MethodHook() {

            override fun beforeHookedMethod(param: MethodHookParam) {
                val impl = param.args.getOrNull(0) ?: return
                val mgr = XposedHelpers.getObjectField(impl, FIELD_MGR) ?: return

                // 已经是 false 就说明流体云本来就没在跑（比如 OShin 那个全局开关开着），
                // 那什么都不用做——经典分支自己会走。
                if (!XposedHelpers.getBooleanField(mgr, FIELD_AVAILABLE)) return

                // 按下去，并把「我们动过手」这件事记在 param 上给 after 看。
                // 用 setObjectExtra 而不是自建字段，是为了可重入：
                // 万一 showH 嵌套调用，各层各记各的，不会互相踩。
                XposedHelpers.setBooleanField(mgr, FIELD_AVAILABLE, false)
                param.setObjectExtra(EXTRA_FLIPPED, mgr)
            }

            override fun afterHookedMethod(param: MethodHookParam) {
                // 只有我们按下去的才还原，绝不无条件写 true
                // ——否则会把 OShin 那个全局关闭给顶掉。
                val mgr = param.getObjectExtra(EXTRA_FLIPPED) as? Any ?: return
                XposedHelpers.setBooleanField(mgr, FIELD_AVAILABLE, true)

                if (logged.compareAndSet(false, true)) {
                    XposedBridge.log("[$TAG] 已生效：三段式开关走经典弹窗，流体云其余场景不受影响")
                }
            }
        })

        XposedBridge.log("[$TAG] 已挂上 ${showH.name}(${showH.parameterTypes.joinToString { it.simpleName }})")
    }

    /**
     * 按签名特征找 showH，不认名字。
     *
     * 命中的是 `-$$Nest$mshowH(OpThreekeyDialogImpl, int) -> void`：
     * Kotlin 为内部类访问外部类私有成员而生成的静态访问器。
     * 名字里的序号（jadx 会显示成 m248$$Nest$mshowH）每次编译都在变，
     * 但「static / 返回 void / 首参是本类 / 次参是 int」这个形状很稳。
     */
    private fun findShowH(implClass: Class<*>): Method? =
        implClass.declaredMethods.firstOrNull { m ->
            Modifier.isStatic(m.modifiers) &&
                m.returnType == Void.TYPE &&
                m.parameterTypes.size == 2 &&
                m.parameterTypes[0] == implClass &&
                m.parameterTypes[1] == Int::class.javaPrimitiveType
        }

    private companion object {
        const val TAG = "三段式无流体云"

        const val PKG_SYSTEMUI = "com.android.systemui"
        const val CLS_DIALOG_IMPL = "com.oplus.systemui.opthreekey.tips.OpThreekeyDialogImpl"

        const val FIELD_MGR = "mSeedlingPluginManager"
        const val FIELD_AVAILABLE = "isPluginAvailable"

        const val EXTRA_FLIPPED = "nocapsule_flipped"
    }
}
