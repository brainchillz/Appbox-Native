import AppBoxKit
import SwiftUI

/// Create sheet. Mirrors the CLI's create commands, including the rules that
/// are easy to get wrong by hand: Rocky has no `latest` tag and Arch is
/// rolling, so the version control adapts per distro.
struct CreateBoxView: View {
    @Bindable var store: BoxStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var distro: Distro = .ubuntu
    @State private var version = ""
    @State private var full = true
    @State private var cpus = ""
    @State private var memory = ""
    @State private var kind: BoxKind = .machine
    @State private var homeMount: HomeMount = .rw

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Only a clash *of the same kind* matters — machines and containers are
    /// separate namespaces in Apple's CLI.
    private var nameIsValid: Bool {
        !trimmedName.isEmpty
            && !trimmedName.contains(" ")
            && !store.boxes.contains { $0.name == trimmedName && $0.kind == kind }
    }

    private var resolvedImage: String {
        let requested = version.trimmingCharacters(in: .whitespaces)
        return distro.image(version: requested.isEmpty ? nil : requested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("dev"))
                        .textFieldStyle(.roundedBorder)

                    Picker("Distribution", selection: $distro) {
                        ForEach(Distro.allCases, id: \.self) { distro in
                            Text(displayName(distro)).tag(distro)
                        }
                    }

                    if distro.isRolling {
                        LabeledContent("Version") {
                            Text("rolling — always latest")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField(
                            "Version", text: $version,
                            prompt: Text(versionPrompt))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if store.machinesAvailable {
                    Section("Kind") {
                        Picker("Kind", selection: $kind) {
                            ForEach(BoxKind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(kind.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if kind == .machine {
                            Picker("Mac home", selection: $homeMount) {
                                Text("Read/write").tag(HomeMount.rw)
                                Text("Read-only").tag(HomeMount.ro)
                                Text("Not mounted").tag(HomeMount.none)
                            }
                            Text(macHomeExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Resources") {
                    TextField("CPUs", text: $cpus, prompt: Text("4"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Memory", text: $memory, prompt: Text("2G"))
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    Toggle("Full Linux install", isOn: $full)
                    Text(fullInstallExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Image", value: resolvedImage)
                        .font(.caption.monospaced())
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if !trimmedName.isEmpty && !nameIsValid {
                    Label(nameProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    store.create(
                        kind: store.machinesAvailable ? kind : .container,
                        name: trimmedName,
                        token: token,
                        bare: !full,
                        cpus: Int(cpus.trimmingCharacters(in: .whitespaces)),
                        memory: memory.isEmpty ? nil : memory,
                        homeMount: kind == .machine ? homeMount : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid)
            }
            .padding(12)
        }
        .frame(width: 460)
    }

    private var nameProblem: String {
        if trimmedName.contains(" ") { return "Name can’t contain spaces." }
        return "A \(kind.rawValue) named “\(trimmedName)” already exists."
    }

    private var macHomeExplanation: String {
        switch homeMount {
        case .rw:
            "Your Mac home appears at /Users/\(NSUserName()) inside. Edit on the Mac, "
                + "build in Linux — the same files, not a copy."
        case .ro:
            "Your Mac files are visible but cannot be changed from inside."
        case .none:
            "The machine cannot see your Mac files at all."
        }
    }

    private var fullInstallExplanation: String {
        switch (kind, full) {
        case (.machine, true):
            return "The standard CLI toolset and an init system, plus sudo, a bash login "
                + "shell and dotfiles for the account Linux creates for you."
        case (.machine, false):
            return "The image exactly as it shipped. Most images have no init system and "
                + "will not boot as a machine — Alpine is the exception."
        case (.container, true):
            return "The standard CLI toolset plus an account matching your Mac user, with "
                + "a home directory kept on the host."
        case (.container, false):
            return "A bare container: no toolset, no user account, root only."
        }
    }

    /// The distro token the CLI would take, e.g. "fedora43".
    private var token: String {
        let requested = version.trimmingCharacters(in: .whitespaces)
        guard !distro.isRolling, !requested.isEmpty, requested != "latest" else {
            return distro.rawValue
        }
        return distro.rawValue + requested
    }

    private var versionPrompt: String {
        switch distro {
        case .ubuntu: "latest (newest LTS) · 24.04 · 26.04"
        case .fedora: "latest · 43 · 44"
        case .rocky: "10 · 9   (no “latest” tag exists)"
        default: "latest"
        }
    }

    private func displayName(_ distro: Distro) -> String {
        switch distro {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .alpine: "Alpine"
        case .fedora: "Fedora"
        case .rocky: "Rocky Linux"
        case .arch: "Arch Linux ARM"
        }
    }
}
