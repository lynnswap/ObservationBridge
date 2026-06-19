import Foundation
import SwiftUI

struct RunnerView: View {
    @State private var model = RunnerModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Run") {
                    LabeledContent("Status") {
                        statusValue
                            .transition(.blurReplace)
                    }
                    .animation(.default, value: model.status)

                    Button(role: model.isRunning ? .destructive : nil) {
                        if model.isRunning {
                            model.cancelRun()
                        } else {
                            model.startRun()
                        }
                    } label: {
                        Label {
                            Text(model.isRunning ? "Cancel" : "Run")
                        } icon: {
                            Image(systemName: model.isRunning ? "stop" : "play")
                                .symbolVariant(.fill)
                                .contentTransition(.symbolEffect(.replace))
#if os(iOS)
                                .foregroundStyle(model.isRunning ? .red : .accentColor)
#endif
                        }
                    }
                    .transition(.blurReplace)
                    .animation(.default, value: model.isRunning)
                }

                Section("Result") {
                    LabeledContent("Elapsed") {
                        Text(formattedElapsed(model.latestResult?.elapsedSeconds))
                            .monospacedDigit()
                    }

                    LabeledContent("Iterations") {
                        Text(formattedCount(model.latestResult?.iterations ?? RunnerConfiguration.iterations))
                            .monospacedDigit()
                    }

                    LabeledContent("Workers") {
                        Text(formattedCount(model.latestResult?.workers))
                            .monospacedDigit()
                    }

                    LabeledContent("Callbacks") {
                        Text(formattedCount(model.latestResult?.observedCallbacks))
                            .monospacedDigit()
                    }

                    LabeledContent("Matches") {
                        Text(formattedCount(model.latestResult?.matchedMutations))
                            .monospacedDigit()
                    }
                }

                if let firstFailure = model.latestResult?.firstFailure {
                    Section("Failure") {
                        Text(firstFailure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Runner")
        }
    }

    @ViewBuilder
    private var statusValue: some View {
        if let statusText = model.status.text {
            Text(statusText)
        } else {
            ProgressView()
#if os(macOS)
                .controlSize(.mini)
#endif
        }
    }

    private func formattedElapsed(_ seconds: Double?) -> String {
        guard let seconds else {
            return "-"
        }
        return Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(3))
                )
            )
    }

    private func formattedCount(_ value: Int?) -> String {
        guard let value else {
            return "-"
        }
        return value.formatted()
    }
}

#Preview {
    RunnerView()
}
