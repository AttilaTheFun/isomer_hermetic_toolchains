// NSLog, as Apple's: the format filled, and the line written where the
// platform's own messages go: logcat on Android (an app's standard error goes
// nowhere there), standard error elsewhere, after a time stamp and the
// process's name and identifier, as Apple's writes it. NSLogv isn't here: it
// takes a C va_list, and this Foundation's String(format:) reads Swift's
// CVarArg values.

import FoundationEssentials
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(ucrt)
import ucrt
#endif

/// Logs a message: the format filled with `args`, as `String(format:)` does.
public func NSLog(_ format: String, _ args: any CVarArg...) {
    let message = String(format: format, arguments: args)
    let process = ProcessInfo.processInfo
    #if canImport(Android)
    // INFO, tagged with the process's name, as logcat shows an app's lines.
    _ = __android_log_write(4, process.processName, message)
    #else
    let line = "\(Date.now.formatted(.iso8601)) \(process.processName)[\(process.processIdentifier)] \(message)\n"
    fputs(line, stderr)
    #endif
}
