import SwiftUI

@MainActor
struct BodyMeasurementsView: View {
    let store: TrackerStore

    var body: some View {
        let latest = Dictionary(uniqueKeysWithValues: BodyMetric.allCases.compactMap { metric in
            store.latestBodyMeasurement(metric)?.current.map { (metric, $0) }
        })
        List {
            Section("Latest measurements") {
                ForEach(BodyMeasurementGroup.common.metrics) { metric in
                    metricLink(metric, latest: latest[metric])
                }
            }

            Section {
                ForEach(BodyMeasurementGroup.allCases.filter { $0 != .common }) { group in
                    DisclosureGroup {
                        ForEach(group.metrics) { metric in
                            metricLink(metric, latest: latest[metric])
                        }
                    } label: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            let recordedCount = group.metrics.filter { latest[$0] != nil }.count
                            Text("\(recordedCount) of \(group.metrics.count) recorded")
                                .font(.footnote)
                                .foregroundStyle(TrackerTheme.muted)
                        }
                    }
                    .accessibilityIdentifier("body.group.\(group.rawValue)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background)
        .environment(\.timeZone, store.calendar.timeZone)
        .navigationTitle("Body measurements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BodyMeasurementEditor(store: store)
                } label: {
                    TrackerTheme.navigationIcon("plus")
                }
                .accessibilityLabel("Add measurements")
                .accessibilityIdentifier("body.add")
            }
        }
    }

    private func metricLink(_ metric: BodyMetric, latest: BodyMeasurementRevision?) -> some View {
        NavigationLink {
            BodyMetricHistoryView(store: store, metric: metric)
        } label: {
            LabeledContent {
                if let latest {
                    VStack(alignment: .trailing, spacing: 3) {
                        BodyMeasurementValue(metric: metric, value: latest.value)
                            .foregroundStyle(TrackerTheme.ink)
                        BodyMeasurementDate(date: latest.measuredAt, includesTime: false)
                            .font(.caption)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                } else {
                    Text("Not recorded").foregroundStyle(TrackerTheme.muted)
                }
            } label: {
                Text(metric.title)
            }
        }
        .accessibilityIdentifier("body.metric.\(metric.rawValue)")
    }
}

@MainActor
struct BodyMetricHistoryView: View {
    let store: TrackerStore
    let metric: BodyMetric
    @State private var comparisonID: String?

    var body: some View {
        let measurements = store.bodyMeasurements(for: metric)
        let dated = measurements.filter { $0.current?.measuredAt != nil }
        let selected = dated.first { $0.id == comparisonID }?.current
        List {
            if let latest = measurements.first?.current {
                let displayed = selected ?? latest
                Section {
                    LabeledContent {
                        BodyMeasurementValue(metric: metric, value: displayed.value)
                            .accessibilityIdentifier("body.history.value")
                    } label: {
                        BodyMeasurementDate(date: displayed.measuredAt)
                    }
                    if !dated.isEmpty {
                        Picker("Comparison time", selection: $comparisonID) {
                            Text("Current measurements").tag(nil as String?)
                            ForEach(dated) { record in
                                if let entry = record.current, let date = entry.measuredAt {
                                    Text("\(date, format: .dateTime.month().day().hour().minute()), \(entry.value, format: .number.precision(.fractionLength(0...6))) \(metric.unit)")
                                        .tag(Optional(record.id))
                                        .accessibilityIdentifier("body.history.compare.\(record.id)")
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("body.history.compare")
                        if let selected {
                            LabeledContent("Change since selected measurement") {
                                BodyMeasurementValue(metric: metric, value: latest.value - selected.value)
                                    .accessibilityIdentifier("body.history.change")
                            }
                        }
                    }
                } header: {
                    Text(selected == nil ? "Latest measurement" : "Historical comparison")
                }
            }

            Section("Measurement history") {
                if measurements.isEmpty {
                    Text("No measurements yet")
                        .foregroundStyle(TrackerTheme.muted)
                        .accessibilityIdentifier("body.history.empty")
                }
                ForEach(measurements) { record in
                    if let current = record.current {
                        NavigationLink {
                            BodyMeasurementRecordView(store: store, metric: metric, recordID: record.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    BodyMeasurementDate(date: current.measuredAt)
                                    Text(record.revisions.count == 1 ? "1 version" : "\(record.revisions.count) versions")
                                        .font(.caption)
                                        .foregroundStyle(TrackerTheme.muted)
                                }
                                Spacer()
                                BodyMeasurementValue(metric: metric, value: current.value)
                                    .foregroundStyle(TrackerTheme.muted)
                            }
                            .padding(.vertical, 3)
                        }
                        .accessibilityIdentifier("body.history.record.\(record.id)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.timeZone, store.calendar.timeZone)
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BodyMeasurementEditor(store: store, metric: metric)
                } label: {
                    TrackerTheme.navigationIcon("plus")
                }
                .accessibilityLabel("Add measurement")
                .accessibilityIdentifier("body.history.add")
            }
        }
        .onChange(of: dated.map(\.id)) { _, available in
            if let comparisonID, !available.contains(comparisonID) { self.comparisonID = nil }
        }
    }
}

@MainActor
private struct BodyMeasurementRecordView: View {
    let store: TrackerStore
    let metric: BodyMetric
    let recordID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var confirmingRestore: BodyMeasurementRevision?
    @State private var saveFailed = false

    private var record: BodyMeasurement? {
        store.bodyMeasurements(for: metric).first { $0.id == recordID }
    }

    var body: some View {
        List {
            if let record, let current = record.current {
                Section {
                    LabeledContent {
                        BodyMeasurementValue(metric: metric, value: current.value)
                    } label: {
                        BodyMeasurementDate(date: current.measuredAt)
                    }
                    .accessibilityIdentifier("body.record.value")
                } header: {
                    Text(metric.title)
                }
                Section("Version history") {
                    ForEach(Array(record.revisions.enumerated().reversed()), id: \.element.id) { index, revision in
                        versionRow(revision, position: index + 1, isCurrent: revision.id == current.id)
                    }
                }
                Section {
                    Button("Delete measurement", role: .destructive) { confirmingDeletion = true }
                        .accessibilityIdentifier("body.record.delete")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Measurement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record, record.current != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Revise") {
                        BodyMeasurementEditor(store: store, metric: metric, record: record)
                    }
                    .accessibilityIdentifier("body.record.revise")
                }
            }
        }
        .confirmationDialog("Delete this measurement?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete measurement", role: .destructive) {
                if store.deleteBodyMeasurement(recordID) { dismiss() }
                else { saveFailed = true }
            }
            .accessibilityIdentifier("body.record.confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the measurement and its saved versions.")
        }
        .confirmationDialog("Restore this version?", isPresented: Binding(
            get: { confirmingRestore != nil }, set: { if !$0 { confirmingRestore = nil } }
        ), titleVisibility: .visible, presenting: confirmingRestore) { revision in
            Button("Restore version") {
                if !store.restoreBodyMeasurement(recordID, revisionID: revision.id) { saveFailed = true }
            }
            .accessibilityIdentifier("body.record.confirmRestore")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Restoring creates a new version.")
        }
        .alert("Could not update body measurements.", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func versionRow(_ revision: BodyMeasurementRevision, position: Int, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Version \(position)").font(.subheadline.weight(.medium))
                Spacer()
                BodyMeasurementValue(metric: metric, value: revision.value)
            }
            BodyMeasurementDate(date: revision.measuredAt)
                .font(.footnote)
                .foregroundStyle(TrackerTheme.muted)
            HStack(alignment: .firstTextBaseline) {
                Text("Saved \(revision.savedAt, format: .dateTime.year().month().day().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
                Spacer()
                if isCurrent {
                    Text("Current version")
                        .font(.caption)
                        .foregroundStyle(TrackerTheme.accent)
                } else {
                    Button("Restore version") { confirmingRestore = revision }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("body.record.restore.\(revision.id)")
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.record.version.\(position)")
    }
}

struct BodyMeasurementValue: View {
    let metric: BodyMetric
    let value: Double
    @Environment(\.locale) private var locale

    var body: some View {
        let number = value.formatted(.number.precision(.fractionLength(0...6)).locale(locale))
        Text(verbatim: "\(number) \(metric.unit)").monospacedDigit()
    }
}

private struct BodyMeasurementDate: View {
    let date: Date?
    var includesTime = true

    var body: some View {
        if let date {
            if includesTime {
                Text(date, format: .dateTime.year().month().day().hour().minute())
            } else {
                Text(date, format: .dateTime.year().month().day())
            }
        } else {
            Text("Measurement time unknown")
        }
    }
}
