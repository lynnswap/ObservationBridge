import Foundation
import SwiftUI

struct RunnerView: View {
    private enum RunnerStatus: Equatable {
        case idle
        case running
        case passed
        case failed

        var text: String? {
            switch self {
            case .idle:
                return "Idle"
            case .running:
                return nil
            case .passed:
                return "Passed"
            case .failed:
                return "Failed"
            }
        }
    }

    @State private var isRunning = false
    @State private var latestResult: RunnerResult?
    @State private var runningTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Run") {
                    LabeledContent("Status") {
                        statusValue
                            .transition(.blurReplace)
                    }
                    .animation(.default, value: status)
                    
                    Button(role: isRunning ? .destructive : nil) {
                        if isRunning {
                            cancelRun()
                        } else {
                            startRun()
                        }
                    } label: {
                        Label{
                            Text(isRunning ? "Cancel" : "Run")
                               
                               
                            
                        }icon:{
                            Image(systemName: isRunning ? "stop" : "play")
                                .symbolVariant(.fill)
                                .contentTransition(.symbolEffect(.replace))
#if os(iOS)
                                .foregroundStyle(isRunning ? .red : .accentColor)
#endif
                        }
                    }
                    .transition(.blurReplace)
                    .animation(.default, value: isRunning)
                }
              

                Section("Result") {
                    LabeledContent("Elapsed") {
                        Text(formattedElapsed(latestResult?.elapsedSeconds))
                            .monospacedDigit()
                    }

                    LabeledContent("Iterations") {
                        Text(formattedCount(latestResult?.iterations ?? RunnerConfiguration.iterations))
                            .monospacedDigit()
                    }

                    LabeledContent("Workers") {
                        Text(formattedCount(latestResult?.workers))
                            .monospacedDigit()
                    }

                    LabeledContent("Callbacks") {
                        Text(formattedCount(latestResult?.observedCallbacks))
                            .monospacedDigit()
                    }

                    LabeledContent("Matches") {
                        Text(formattedCount(latestResult?.matchedMutations))
                            .monospacedDigit()
                    }
                }

                if let firstFailure = latestResult?.firstFailure {
                    Section("Failure") {
                        Text(firstFailure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Runner")
        }
    }

    private var status: RunnerStatus {
        if isRunning {
            return .running
        }

        guard let latestResult else {
            return .idle
        }

        if latestResult.firstFailure == nil, latestResult.completed {
            return .passed
        }

        return .failed
    }

    @ViewBuilder
    private var statusValue: some View {
        if let statusText = status.text {
            Text(statusText)
        } else {
            ProgressView()
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

    private func startRun() {
        guard !isRunning else {
            return
        }

        isRunning = true
        latestResult = nil

        runningTask = Task {
            let result = await Runner.run()

            if Task.isCancelled {
                return
            }

            await MainActor.run {
                latestResult = result
                isRunning = false
                runningTask = nil
            }
        }
    }

    private func cancelRun() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
    }
}

#Preview {
    RunnerView()
}
