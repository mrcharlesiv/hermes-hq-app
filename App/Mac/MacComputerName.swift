// [mac-audit] Owner 2026-11-02 (#22): this Mac's name, for a gateway at a loopback address (`GatewayNaming.thisComputer`):
// More's gateway card read "127.0.0.1:9881". The name System Settings › General › Sharing shows ("alex’s Mac
// Studio"), else the local host name ("alexs-Mac-Studio", read the way a .local address is). Both come from
// SystemConfiguration's public C functions, which the Catalyst SDK marks unavailable though the Mac's framework has
// them, so they are looked up at run time; `UIDevice.name` answers only "Mac" and the DNS host name reads
// "alexacStudio".

import Foundation

#if targetEnvironment(macCatalyst)
enum MacComputerName {
    private typealias CopyComputerName = @convention(c) (CFTypeRef?, UnsafeMutablePointer<UInt32>?) -> Unmanaged<CFString>?
    private typealias CopyLocalHostName = @convention(c) (CFTypeRef?) -> Unmanaged<CFString>?

    static var current: String? {
        guard let framework = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY) else { return nil }
        if let symbol = dlsym(framework, "SCDynamicStoreCopyComputerName") {
            let copy = unsafeBitCast(symbol, to: CopyComputerName.self)
            if let name = copy(nil, nil)?.takeRetainedValue() as String?, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name
            }
        }
        if let symbol = dlsym(framework, "SCDynamicStoreCopyLocalHostName") {
            let copy = unsafeBitCast(symbol, to: CopyLocalHostName.self)
            if let local = copy(nil)?.takeRetainedValue() as String?, !local.isEmpty {
                let name = GatewayNaming.friendlyName(URL(string: "http://\(local).local"))
                return name == GatewayNaming.unnamed ? nil : name
            }
        }
        return nil
    }
}
#endif
