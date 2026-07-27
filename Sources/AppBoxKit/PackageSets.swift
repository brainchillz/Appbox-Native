import Foundation

/// The standard "everyday Linux" CLI toolset installed by `provision` and by
/// `--full`. No desktop or UI packages — just what you'd expect on a normal
/// server login. Package names differ per distro for the same tool, which is
/// why these are four hand-maintained lists rather than one.
public enum PackageSets {
    public static let apt = [
        "iproute2", "iputils-ping", "net-tools", "dnsutils", "curl", "wget",
        "ca-certificates", "vim", "nano", "less", "man-db", "manpages", "sudo",
        "openssh-client", "git", "htop", "procps", "psmisc", "tmux", "unzip",
        "zip", "xz-utils", "rsync", "file", "lsof", "tree", "jq", "gnupg",
        "bash-completion",
    ]

    public static let dnf = [
        "iproute", "iputils", "net-tools", "bind-utils", "curl", "wget",
        "ca-certificates", "vim-enhanced", "nano", "less", "man-db", "sudo",
        "openssh-clients", "git", "htop", "procps-ng", "psmisc", "tmux",
        "unzip", "zip", "xz", "rsync", "file", "lsof", "tree", "jq", "gnupg2",
        "bash-completion",
    ]

    public static let apk = [
        "iproute2", "iputils", "bind-tools", "curl", "wget", "ca-certificates",
        "vim", "nano", "less", "mandoc", "sudo", "openssh-client", "git",
        "htop", "procps", "psmisc", "tmux", "unzip", "zip", "xz", "rsync",
        "file", "lsof", "tree", "jq", "gnupg", "bash", "bash-completion",
    ]

    public static let pacman = [
        "iproute2", "iputils", "bind", "curl", "wget", "ca-certificates",
        "vim", "nano", "less", "man-db", "man-pages", "sudo", "openssh", "git",
        "htop", "procps-ng", "psmisc", "tmux", "unzip", "zip", "xz", "rsync",
        "file", "lsof", "tree", "jq", "gnupg", "bash-completion",
    ]

    public static func packages(for manager: PackageManager) -> [String] {
        switch manager {
        case .apt: apt
        case .dnf: dnf
        case .apk: apk
        case .pacman: pacman
        }
    }

    /// The shell command that installs the toolset with the given manager.
    ///
    /// `pacman --disable-sandbox`: pacman 7's downloader sandbox uses Landlock,
    /// which Apple's container kernel does not support — without this it fails
    /// with "restricting filesystem access failed because Landlock is not
    /// supported by the kernel". Add it to any manual pacman run inside a box.
    public static func installCommand(for manager: PackageManager) -> String {
        let list = packages(for: manager).joined(separator: " ")
        switch manager {
        case .apt:
            return "export DEBIAN_FRONTEND=noninteractive; "
                + "apt-get update -qq && apt-get install -y --no-install-recommends \(list)"
        case .dnf:
            // dnf aborts the *entire* transaction if any single package is
            // unavailable, and htop ships in EPEL rather than Rocky's default
            // repos — so a plain `dnf install` installs nothing at all on
            // Rocky. Skip what isn't there instead.
            //
            // The flag differs by generation: dnf5 (Fedora 41+) has
            // --skip-unavailable; dnf4 (Rocky 10 ships 4.20) does not and needs
            // --setopt=strict=0. Probe rather than guess.
            return """
                if dnf --help 2>&1 | grep -q -- '--skip-unavailable'; then \
                skip='--skip-unavailable'; \
                else skip='--setopt=strict=0 --skip-broken'; fi; \
                dnf install -y $skip \(list)
                """
        case .apk:
            return "apk add --no-cache \(list)"
        case .pacman:
            return "pacman -Syu --noconfirm --needed --disable-sandbox \(list)"
        }
    }
}
