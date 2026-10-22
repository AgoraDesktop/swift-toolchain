/*
 * The Objective-C runtime's C surface, for the `ObjectiveC` module.
 *
 * Darwin's `ObjectiveC` is an overlay over a Clang module of `objc/objc.h` and
 * `objc/runtime.h`, so `import ObjectiveC` there gives `objc_getClass` and
 * friends. Agora's runtime headers are not a Clang module; making them one was
 * tried (a `module ObjectiveC` in the Foundation map, with the overlay built
 * `-import-underlying-module`) and it works for compilation but **not for module
 * interfaces**: a Swift module with an underlying Clang module cannot pass
 * `-verify-emitted-module-interface`, because the verifier re-parses the
 * interface without the `-Xcc` flags that locate the map. swift-testing emits an
 * interface (`-enable-library-evolution`), so that path is closed for now.
 *
 * These wrappers are the contained alternative: names a Swift `_silgen_name`
 * may use (the runtime's own `objc_`-prefixed names are "reserved for the Swift
 * runtime", a warning today and an error later), implemented against the real
 * runtime and linked into `libObjectiveC.so`.
 */
#include <objc/objc.h>
#include <objc/runtime.h>

void *agora_objc_getClass(const char *name) {
	return (void *)objc_getClass(name);
}

void *agora_objc_lookUpClass(const char *name) {
	return (void *)objc_lookUpClass(name);
}

void *agora_object_getClass(void *obj) {
	return (void *)object_getClass((id)obj);
}

const char *agora_class_getName(void *cls) {
	return class_getName((Class)cls);
}
