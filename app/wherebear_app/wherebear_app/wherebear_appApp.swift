//
//  wherebear_appApp.swift
//  wherebear_app
//
//  kc_wherebear — app entry: build the 7 logic objects, inject, mount RootView.
//

import SwiftUI

@main
struct wherebear_appApp: App {
    @State private var session = SupabaseSession()
    @State private var reporter = LocationReporter()
    @State private var vm = LocationVM()
    @State private var photo = PhotoImporter()
    @State private var keys = ApiKeyManager()
    @State private var profile = ProfileManager()
    @State private var landmarks = LandmarkManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(reporter)
                .environment(vm)
                .environment(photo)
                .environment(keys)
                .environment(profile)
                .environment(landmarks)
        }
    }
}
