//
//  Logger.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/16.
//

import Foundation

class Logger {
    private init() {}
    static let queue = DispatchQueue (label: "bitkit.log", qos: .utility)
    
    static func info(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("INFOℹ️: \(message)", context: context, file: file, function: function, line: line)
    }
    
    static func debug(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("DEBUG: \(message)", context: context, file: file, function: function, line: line)
    }
    
    static func warn(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("WARN⚠️: \(message)", context: context, file: file, function: function, line: line)
    }
    
    static func error(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("ERROR❌: \(message)", context: context, file: file, function: function, line: line)
    }
    
    static func test(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("🧪🧪🧪: \(message)", context: context, file: file, function: function, line: line)
    }
    
    static func performance(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("PERF: \(message)", context: context, file: file, function: function, line: line)
    }
    
    private static func handle(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let line = "\(message) \(context == "" ? "" : "- \(context) ")[\(fileName): \(function) line: \(line)]"
        
        print(line)
        
        queue.async {
            //TODO write to file
        }
    }
}
