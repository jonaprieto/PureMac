//
//  AppConstants.swift
//  PureMac
//
//  Created by Theo Sementa on 12/04/2026.
//

import Foundation

struct AppConstants {
    
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

}
