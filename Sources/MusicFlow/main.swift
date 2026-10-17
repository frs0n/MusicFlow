import AppKit
import MetalKit

if CommandLine.arguments.contains("--validate") {
    do {
        let args=CommandLine.arguments
        let path=args.firstIndex(of:"--output").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? "Validation"
        try runValidation(output:URL(fileURLWithPath:path,isDirectory:true))
    } catch {fputs("Validation failed: \(error)\n",stderr);exit(1)}
} else {
    let app=NSApplication.shared
    let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
}
