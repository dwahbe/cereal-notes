import Foundation
import ObjectiveC
import Testing

@Suite("CATapDescription Introspection", .serialized)
struct CATapIntrospectionTests {
    @Test("Dump CATapDescription methods")
    func dumpMethods() {
        guard let cls = NSClassFromString("CATapDescription") else {
            print("CATapDescription class not found")
            return
        }

        print("CATapDescription class found: \(cls)")
        print("\nInstance methods:")
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            for i in 0..<Int(methodCount) {
                let sel = method_getName(methods[i])
                let name = NSStringFromSelector(sel)
                let typeEncoding = method_getTypeEncoding(methods[i]).map { String(cString: $0) } ?? "?"
                print("  - \(name)  [\(typeEncoding)]")
            }
            free(methods)
        }
        print("Total instance methods: \(methodCount)")

        print("\nClass methods:")
        if let metaCls = object_getClass(cls) {
            var classMethodCount: UInt32 = 0
            if let methods = class_copyMethodList(metaCls, &classMethodCount) {
                for i in 0..<Int(classMethodCount) {
                    let sel = method_getName(methods[i])
                    let name = NSStringFromSelector(sel)
                    print("  + \(name)")
                }
                free(methods)
            }
            print("Total class methods: \(classMethodCount)")
        }

        print("\nProperties:")
        var propCount: UInt32 = 0
        if let props = class_copyPropertyList(cls, &propCount) {
            for i in 0..<Int(propCount) {
                let name = String(cString: property_getName(props[i]))
                let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? "?"
                print("  \(name)  [\(attrs)]")
            }
            free(props)
        }
        print("Total properties: \(propCount)")

        // Check superclass chain
        print("\nSuperclass chain:")
        var current: AnyClass? = cls
        while let c = current {
            print("  \(c)")
            current = class_getSuperclass(c)
        }

        // Check specific selectors
        let selectors = [
            "initMonoGlobalTapButExcludeProcesses:",
            "initWithProcesses:andDevices:andExcludeProcesses:",
            "init",
            "initWithProcesses:",
            "initStereoGlobalTapButExcludeProcesses:",
            "initStereoMixdownGlobalTapButExcludeProcesses:",
        ]
        print("\nSelector checks:")
        for selName in selectors {
            let sel = NSSelectorFromString(selName)
            let responds = cls.instancesRespond(to: sel)
            print("  \(selName): \(responds)")
        }
    }

    @Test("Try basic init")
    func basicInit() {
        guard let cls = NSClassFromString("CATapDescription") else { return }
        let obj = (cls as! NSObject.Type).init()
        print("Init succeeded: \(obj)")
        print("Type: \(type(of: obj))")
    }
}
