// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import Android
import CAndroidNDK
import Foundation

/// Calls Android framework APIs over JNI when the C NDK does not expose them, such as runtime permissions,
/// starting activities, and reading the user-assigned device name.
///
/// Methods look up standard Android classes by name and signature so the APK does not need custom Java
/// subclasses. If a JNI call throws a Java exception, `Java` clears it and returns `nil` or `false`.
struct Java {
    let env: UnsafeMutablePointer<JNIEnv?>
    private var calls: JNINativeInterface { env.pointee!.pointee }

    /// Runs `body` with the calling thread attached to the virtual machine, detaching again if it was not
    /// attached before. Local references made inside are released on return.
    static func attached<Result>(to vm: UnsafeMutablePointer<JavaVM?>, _ body: (Java) -> Result) -> Result? {
        var raw: UnsafeMutableRawPointer?
        var attachedHere = false
        if vm.pointee!.pointee.GetEnv(vm, &raw, JNI_VERSION_1_6) != JNI_OK {
            var environment: UnsafeMutablePointer<JNIEnv?>?
            guard vm.pointee!.pointee.AttachCurrentThread(vm, &environment, nil) == JNI_OK else { return nil }
            raw = UnsafeMutableRawPointer(environment)
            attachedHere = true
        }
        defer { if attachedHere { _ = vm.pointee!.pointee.DetachCurrentThread(vm) } }
        guard let raw else { return nil }
        let java = Java(env: raw.assumingMemoryBound(to: JNIEnv?.self))
        guard java.calls.PushLocalFrame(java.env, 32) == JNI_OK else { return nil }
        defer { _ = java.calls.PopLocalFrame(java.env, nil) }
        return body(java)
    }

    /// Clears any pending Java exception and returns `true` if one was thrown.
    @discardableResult
    private func threw() -> Bool {
        guard calls.ExceptionCheck(env) != 0 else { return false }
        calls.ExceptionClear(env)
        return true
    }

    func string(_ text: String) -> jobject? {
        calls.NewStringUTF(env, text)
    }

    func text(_ string: jobject?) -> String? {
        guard let string, let characters = calls.GetStringUTFChars(env, string, nil) else { return nil }
        defer { calls.ReleaseStringUTFChars(env, string, characters) }
        return String(cString: characters)
    }

    func strings(_ texts: [String]) -> jobject? {
        guard let kind = calls.FindClass(env, "java/lang/String"),
              let array = calls.NewObjectArray(env, jsize(texts.count), kind, nil)
        else { return nil }
        for (index, text) in texts.enumerated() { calls.SetObjectArrayElement(env, array, jsize(index), string(text)) }
        return array
    }

    private func method(of object: jobject?, _ name: String, _ signature: String) -> jmethodID? {
        guard let object, let kind = calls.GetObjectClass(env, object) else { return nil }
        let found = calls.GetMethodID(env, kind, name, signature)
        return threw() ? nil : found
    }

    func object(_ target: jobject?, _ name: String, _ signature: String, _ arguments: [jvalue] = []) -> jobject? {
        guard let method = method(of: target, name, signature) else { return nil }
        let result = calls.CallObjectMethodA(env, target, method, arguments)
        return threw() ? nil : result
    }

    func int(_ target: jobject?, _ name: String, _ signature: String, _ arguments: [jvalue] = []) -> Int32? {
        guard let method = method(of: target, name, signature) else { return nil }
        let result = calls.CallIntMethodA(env, target, method, arguments)
        return threw() ? nil : result
    }

    @discardableResult
    func void(_ target: jobject?, _ name: String, _ signature: String, _ arguments: [jvalue] = []) -> Bool {
        guard let method = method(of: target, name, signature) else { return false }
        calls.CallVoidMethodA(env, target, method, arguments)
        return !threw()
    }

    func staticObject(_ className: String, _ name: String, _ signature: String, _ arguments: [jvalue] = []) -> jobject? {
        guard let kind = calls.FindClass(env, className), !threw(),
              let method = calls.GetStaticMethodID(env, kind, name, signature), !threw()
        else {
            threw()
            return nil
        }
        let result = calls.CallStaticObjectMethodA(env, kind, method, arguments)
        return threw() ? nil : result
    }

    func new(_ className: String, _ signature: String = "()V", _ arguments: [jvalue] = []) -> jobject? {
        guard let kind = calls.FindClass(env, className), !threw(),
              let method = calls.GetMethodID(env, kind, "<init>", signature), !threw()
        else {
            threw()
            return nil
        }
        let result = calls.NewObjectA(env, kind, method, arguments)
        return threw() ? nil : result
    }

    func stringField(_ target: jobject?, _ name: String) -> String? {
        guard let target, let kind = calls.GetObjectClass(env, target),
              let field = calls.GetFieldID(env, kind, name, "Ljava/lang/String;"), !threw()
        else {
            threw()
            return nil
        }
        return text(calls.GetObjectField(env, target, field))
    }
}

/// Wraps `android.app.Activity` calls over JNI.
struct ActivityCalls {
    let java: Java
    /// Underlying Java `Activity` reference (`ANativeActivity.clazz`).
    let activity: jobject

    /// Returns whether `permission` is currently granted.
    func has(_ permission: String) -> Bool {
        java.int(activity, "checkSelfPermission", "(Ljava/lang/String;)I", [jvalue(l: java.string(permission))]) == 0
    }

    /// Returns whether `permission` is defined on this system (Android XR permissions do not exist on other
    /// headsets and would be auto-denied without a dialog).
    func knows(_ permission: String) -> Bool {
        let packages = java.object(activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        return java.object(packages, "getPermissionInfo", "(Ljava/lang/String;I)Landroid/content/pm/PermissionInfo;",
                           [jvalue(l: java.string(permission)), jvalue(i: 0)]) != nil
    }

    /// Displays the system runtime permission dialog for `permissions`. Because receiving
    /// `onRequestPermissionsResult` requires a Java `Activity` subclass, callers watch activity pause/resume and
    /// re-check `has(_:)`.
    func request(_ permissions: [String]) {
        java.void(activity, "requestPermissions", "([Ljava/lang/String;I)V", [jvalue(l: java.strings(permissions)), jvalue(i: 1)])
    }

    /// Reads the user-assigned device name from `Settings.Global`, if set.
    func deviceName() -> String? {
        let resolver = java.object(activity, "getContentResolver", "()Landroid/content/ContentResolver;")
        let name = java.text(java.staticObject("android/provider/Settings$Global", "getString",
                                               "(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;",
                                               [jvalue(l: resolver), jvalue(l: java.string("device_name"))]))
        return name?.isEmpty == false ? name : nil
    }

    /// Returns the launched component class name (for example, `android.app.NativeActivity` or the `.Panel` alias).
    func componentClass() -> String? {
        let intent = java.object(activity, "getIntent", "()Landroid/content/Intent;")
        let component = java.object(intent, "getComponent", "()Landroid/content/ComponentName;")
        return java.text(java.object(component, "getClassName", "()Ljava/lang/String;"))
    }

    func packageName() -> String? {
        java.text(java.object(activity, "getPackageName", "()Ljava/lang/String;"))
    }

    /// Returns `versionName` from the package's `PackageInfo`.
    func versionName() -> String? {
        let packages = java.object(activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        let info = java.object(packages, "getPackageInfo", "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                               [jvalue(l: java.string(packageName() ?? "")), jvalue(i: 0)])
        return java.stringField(info, "versionName")
    }

    /// Launches another activity in this package in a new task.
    @discardableResult
    func start(activityClass: String) -> Bool {
        guard let package = packageName(), let intent = java.new("android/content/Intent") else { return false }
        _ = java.object(intent, "setClassName", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
                        [jvalue(l: java.string(package)), jvalue(l: java.string(activityClass))])
        _ = java.object(intent, "addFlags", "(I)Landroid/content/Intent;", [jvalue(i: 0x1000_0000)])       // FLAG_ACTIVITY_NEW_TASK
        return java.void(activity, "startActivity", "(Landroid/content/Intent;)V", [jvalue(l: intent)])
    }
}
#endif
