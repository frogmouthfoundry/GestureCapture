//
//  ContentView.swift
//  GestureCapture
//
//  Three sections in a side tab bar: Gestures (library), Record, Live Test.
//  Top ornament: hand-tracking status. Bottom ornament: Track Hands button.
//

import AVKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    enum Section: Hashable { case gestures, record, liveTest }
    @State private var section: Section = .gestures
    @State private var newGestureName = ""

    var body: some View {
        @Bindable var appModel = appModel
        TabView(selection: $section) {
            Tab("Gestures", systemImage: "hand.raised", value: .gestures) {
                GesturesSection()
            }
            Tab("Record", systemImage: "record.circle", value: .record) {
                RecordSection()
            }
            Tab("Live Test", systemImage: "waveform.badge.magnifyingglass", value: .liveTest) {
                LiveTestSection()
            }
        }
        .ornament(attachmentAnchor: .scene(.top)) {
            TrackingStatusBadge()
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            ToggleImmersiveSpaceButton()
                .padding(8)
                .glassBackgroundEffect()
        }
        .sheet(isPresented: Binding(
            get: { appModel.pendingTake != nil },
            set: { if !$0 { appModel.pendingTake = nil } }
        )) {
            namingSheet
        }
        .onChange(of: appModel.recorder.phase) { old, new in
            appModel.recorderPhaseChanged(from: old, to: new)
        }
        .alert("Error", isPresented: Binding(
            get: { appModel.lastError != nil },
            set: { if !$0 { appModel.lastError = nil } }
        )) {
            Button("OK") { appModel.lastError = nil }
        } message: {
            Text(appModel.lastError ?? "")
        }
    }

    private var namingSheet: some View {
        VStack(spacing: 20) {
            Text("Name this gesture").font(.title2)
            TextField("e.g. Thumbs Up", text: $newGestureName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Button("Discard", role: .destructive) {
                    appModel.pendingTake = nil
                    newGestureName = ""
                }
                Button("Save") {
                    appModel.savePendingTake(named: newGestureName.isEmpty ? "Untitled" : newGestureName)
                    newGestureName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newGestureName.isEmpty)
            }
        }
        .padding(32)
    }
}

// MARK: - Tracking status (top ornament)

struct TrackingStatusBadge: View {
    @Environment(AppModel.self) private var appModel

    private var isTracking: Bool { appModel.immersiveSpaceState == .open }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isTracking ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
            Text(isTracking ? "Tracking Hands" : "Not Tracking Hands")
                .font(.callout)
                .foregroundStyle(isTracking ? .primary : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}

// MARK: - Gestures section

struct GesturesSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(appModel.store.gestures) { gesture in
                    GestureRow(gesture: gesture).tag(gesture.id)
                }
                .onDelete { offsets in
                    for index in offsets {
                        appModel.store.delete(appModel.store.gestures[index])
                    }
                }
            }
            .navigationTitle("Gestures")
            .overlay {
                if appModel.store.gestures.isEmpty {
                    ContentUnavailableView("No gestures yet",
                                           systemImage: "hand.wave",
                                           description: Text("Use the Record tab to capture one."))
                }
            }
        } detail: {
            if let gesture = appModel.store.gestures.first(where: { $0.id == selection }) {
                GestureDetailView(gesture: gesture)
            } else {
                ContentUnavailableView("Select a gesture", systemImage: "hand.raised")
            }
        }
    }
}

struct GestureRow: View {
    let gesture: GestureFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: gesture.type == .pose ? "hand.raised.fill" : "hand.draw.fill")
                .foregroundStyle(gesture.type == .pose ? .green : .orange)
            VStack(alignment: .leading) {
                Text(gesture.name).font(.headline)
                Text("\(gesture.handedness.rawValue) · \(gesture.samples.count) take\(gesture.samples.count == 1 ? "" : "s") · \(gesture.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GestureDetailView: View {
    @Environment(AppModel.self) private var appModel
    let gesture: GestureFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                preview
                metadata
                actions
            }
            .padding(24)
        }
        .navigationTitle(gesture.name)
    }

    @ViewBuilder
    private var preview: some View {
        if appModel.previewBusy.contains(gesture.id) {
            ProgressView("Rendering preview…")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if gesture.type == .motion, appModel.store.hasVideo(gesture) {
            VideoPlayer(player: AVPlayer(url: appModel.store.videoURL(for: gesture.id)))
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else if let image = UIImage(contentsOfFile: appModel.store.thumbnailURL(for: gesture.id).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ContentUnavailableView("No preview yet", systemImage: "photo")
                .frame(minHeight: 160)
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow { Text("Type").foregroundStyle(.secondary); Text(gesture.type.rawValue) }
            GridRow { Text("Hands").foregroundStyle(.secondary); Text(gesture.handedness.rawValue) }
            GridRow { Text("Takes").foregroundStyle(.secondary); Text("\(gesture.samples.count)") }
            GridRow {
                Text("Frames").foregroundStyle(.secondary)
                Text("\(gesture.samples.first?.frames.count ?? 0) @ \(Int(gesture.sampleRate)) fps")
            }
            GridRow {
                Text("Orientation").foregroundStyle(.secondary)
                Text(gesture.orientationSensitive ? "sensitive" : "invariant")
            }
        }
        .font(.callout)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    appModel.replayGesture = gesture
                } label: {
                    Label("Replay in Space", systemImage: "play.circle")
                }
                .disabled(appModel.immersiveSpaceState != .open)

                if appModel.replayGesture != nil {
                    Button("Stop Replay") { appModel.replayGesture = nil }
                }
            }
            HStack {
                Button {
                    appModel.startRecording(appendingTo: gesture)
                } label: {
                    Label("Record Another Take", systemImage: "plus.circle")
                }
                .disabled(appModel.immersiveSpaceState != .open)

                Button {
                    appModel.regeneratePreviews(for: gesture)
                } label: {
                    Label("Re-render Preview", systemImage: "arrow.clockwise")
                }
            }
            HStack {
                ShareLink(item: appModel.store.jsonURL(for: gesture.id)) {
                    Label("Share JSON", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    appModel.store.delete(gesture)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Record section

struct RecordSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var flash = false

    var body: some View {
        @Bindable var appModel = appModel
        HStack(spacing: 0) {
            settings
                .frame(width: 340)
            Divider()
            recordPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: appModel.recorder.phase) { _, new in
            if new == .finished, appModel.activeCaptureMode != .snapshot {
                flash = true
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeOut(duration: 0.5)) { flash = false }
                }
            }
        }
    }

    private var settings: some View {
        @Bindable var appModel = appModel
        return Form {
            Section("Capture") {
                Picker("Mode", selection: $appModel.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Hands", selection: $appModel.captureHandedness) {
                    Text("Either").tag(Handedness.either)
                    Text("Left").tag(Handedness.left)
                    Text("Right").tag(Handedness.right)
                    Text("Bimanual").tag(Handedness.bimanual)
                }

                Toggle("Orientation sensitive", isOn: $appModel.orientationSensitive)
            }
            Section("Output") {
                Toggle("Save previews to Photos", isOn: $appModel.saveToPhotos)
            }
        }
        .navigationTitle("Record")
    }

    @ViewBuilder
    private var recordPane: some View {
        ZStack {
            switch appModel.recorder.phase {
            case .idle, .finished:
                VStack(spacing: 24) {
                    Button {
                        appModel.startRecording()
                    } label: {
                        ZStack {
                            Circle().fill(.red.opacity(0.85)).frame(width: 160, height: 160)
                            Image(systemName: "record.circle")
                                .font(.system(size: 64))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.immersiveSpaceState != .open)
                    .opacity(appModel.immersiveSpaceState == .open ? 1 : 0.35)

                    Text(appModel.immersiveSpaceState == .open
                         ? "Record \(appModel.captureMode.label.lowercased())"
                         : "Tap “Track Hands” below to begin")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            case .countdown(let n):
                Text("\(n)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .id(n)
            case .recording(let progress):
                if appModel.activeCaptureMode == .snapshot {
                    Image(systemName: "camera.shutter.button.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(.green)
                } else {
                    let duration = appModel.activeCaptureMode?.captureDuration ?? 0
                    Text(String(format: "%.1f", progress * duration))
                        .font(.system(size: 140, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message).font(.title3)
                    Button("Try Again") { appModel.startRecording() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
            }

            Rectangle()
                .fill(.white)
                .opacity(flash ? 0.8 : 0)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .animation(.default, value: appModel.recorder.phase)
    }
}

// MARK: - Live Test section

struct LiveTestSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 0) {
            libraryList
                .frame(width: 340)
            Divider()
            matchPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            appModel.liveTestEnabled = true
            appModel.lastMatch = nil
            appModel.lastEventDescription = ""
        }
        .onDisappear {
            appModel.liveTestEnabled = false
        }
    }

    private var libraryList: some View {
        List(appModel.store.gestures) { gesture in
            GestureRow(gesture: gesture)
                .opacity(0.9)
        }
        .allowsHitTesting(false)
        .navigationTitle("Live Test")
        .overlay {
            if appModel.store.gestures.isEmpty {
                ContentUnavailableView("Library is empty", systemImage: "hand.wave")
            }
        }
    }

    @ViewBuilder
    private var matchPane: some View {
        if appModel.immersiveSpaceState != .open {
            VStack(spacing: 12) {
                Image(systemName: "hand.raised.slash").font(.system(size: 48))
                Text("Tap “Track Hands” below to begin").font(.title2)
            }
            .foregroundStyle(.secondary)
        } else if let match = appModel.lastMatch {
            VStack(spacing: 20) {
                Text(match.name)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                Text("\(Int(match.confidence * 100))% match")
                    .font(.title)
                    .foregroundStyle(.green)
                if let image = UIImage(contentsOfFile: appModel.store.thumbnailURL(for: match.id).path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 48))
                Text("Perform a gesture from your library…")
                    .font(.title2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
