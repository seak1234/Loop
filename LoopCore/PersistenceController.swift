//
//  PersistenceController.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import LoopKit


extension PersistenceController {
    public class func controllerInAppGroupDirectory(isReadOnly: Bool = false) -> PersistenceController {
        let appGroup = Bundle.main.appGroupSuiteName
        let directoryURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let resolvedURL = directoryURL else {
            assertionFailure("Could not get a container directory URL. Please ensure App Groups are set up correctly in entitlements.")
            return self.init(directoryURL: URL(fileURLWithPath: "/"))
        }

        let isReadOnly = isReadOnly || Bundle.main.isAppExtension

        return self.init(directoryURL: resolvedURL.appendingPathComponent("com.loopkit.LoopKit", isDirectory: true), isReadOnly: isReadOnly)
    }

    public class func controllerInLocalDirectory() -> PersistenceController {
        guard let directoryURL = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            fatalError("Could not access the document directory of the current process")
        }

        let isReadOnly = Bundle.main.isAppExtension

        return self.init(directoryURL: directoryURL.appendingPathComponent("com.loopkit.LoopKit"), isReadOnly: isReadOnly)
    }
}
