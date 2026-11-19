//
//  Log.swift
//  GTNW Chess
//
//  One os.Logger per subsystem area for diagnostics (Console.app / `log stream --predicate
//  'subsystem == "com.jkoch.gtnwchess"'`). `print` is kept only for the headless CLI's own output (--selftest,
//  --setup-credentials). Never log secrets, passwords or model reply text.
//

import os

enum Log {
    static let subsystem = "com.jkoch.gtnwchess"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let lan = Logger(subsystem: subsystem, category: "lan")
    static let play = Logger(subsystem: subsystem, category: "play")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let audio = Logger(subsystem: subsystem, category: "audio")

    static let categories = ["app", "engine", "store", "lan", "play", "ai", "audio"]
}
